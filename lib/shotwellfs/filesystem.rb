require 'shotwellfs/transform'
require 'fusefs/sqlitemapper'
require 'date'
require 'set'
require 'fileutils'
require 'ffi-xattr'
require 'sys/filesystem'
require 'rb-inotify'

module ShotwellFS

    # A Fuse filesystem over a shotwell picture/video library
    class FileSystem < FuseFS::SqliteMapperFS

        def self.source_type(value)
            value.start_with?("video") ? "video" : "photo" 
        end

        def self.source_id(value)
            value[6..-1].hex 
        end


        Event = Struct.new('Event', :id, :path, :time, :xattr)

        SHOTWELL_SQL = <<-SQL
        SELECT P.rating as 'rating', P.exposure_time as 'exposure_time',
               P.title as 'title', P.comment as 'comment', P.filename as 'filename', P.id as 'id',
               P.event_id as 'event_id', "photo" as 'type', P.transformations as 'transformations'
        FROM phototable P
        WHERE P.rating >= %1$d and P.event_id > 0
        UNION
        SELECT V.rating, V.exposure_time as 'exposure_time',
               V.title, V.comment, V.filename as 'filename', V.id as 'id',
               V.event_id as 'event_id', "video" as 'type', null
        FROM videotable V
        WHERE V.rating >= %1$d  and V.event_id > 0
        SQL

        TAG_SQL = <<-SQL
        select name,photo_id_list
        FROM tagtable
        SQL

        EVENT_SQL = <<-SQL
        SELECT E.id as 'id', E.name as 'name', E.comment as 'comment', P.exposure_time as 'exposure_time'
        FROM eventtable E, phototable P
        WHERE source_type(E.primary_source_id) = 'photo'
        AND source_id(E.primary_source_id) = P.id
        UNION
        SELECT E.id, E.name, E.comment, V.exposure_time
        FROM eventtable E, videotable V
        WHERE source_type(E.primary_source_id) = 'video'
        AND source_id(E.primary_source_id) = V.id
        SQL

        XATTR_TRANSFORM_ID = 'user.shotwell.transform_id'

        def initialize(options)
            @shotwell_dir = options[:device]
            shotwell_db = "#{@shotwell_dir}/data/photo.db"

            # Default event name if it is not set - date expression based on exposure time of primary photo
            @event_name = options[:event_name] || "%d %a"

            # Event to path conversion.
            # id, name, comment
            # via event.exposure_time.strftime() and sprintf(format,event)
            @event_path = options[:event_path] || "%Y-%m %{name}"

            # File names (without extension
            @photo_path = options[:photo_path] || "%{id}"

            @video_path = options[:video_path] || @photo_path

            example_event = { id:  1, name: "<event name>", comment: "<event comment>", exposure_time: 0} 

            example_photo = { id: 1000, title: "<photo title>", comment: "<photo comment>",
                rating:5, exposure_time: Time.now.to_i, filename: "photo.jpg", type: "photo" }
            example_video = { id: 1000, title: "<photo title>", comment: "<photo comment>",
                rating:5, exposure_time: Time.now.to_i, filename: "video.mp4", type: "video" }

            event_path = event_path(example_event)

            puts "Mapping paths as\n#{file_path(event_path,example_photo)}\n#{file_path(event_path,example_video)}"

            min_rating  = options[:rating] || 0

            sql = sprintf(SHOTWELL_SQL,min_rating)

            super(shotwell_db,sql,use_raw_file_access: true)
        end

        def transforms_dir
            unless @transforms_dir
                @transforms_dir = "#{@shotwell_dir}/fuse/transforms"
                FileUtils.mkdir_p(@transforms_dir) unless File.directory?(@transforms_dir)
            end
            @transforms_dir
        end

        def transform_required?(filename,transform_id)
            !(File.exists?(filename) && transform_id.eql?(Xattr.new(filename)[XATTR_TRANSFORM_ID]))
        end

        def transform(row)
            if row[:transformations]

                transformations = Transform.new(row[:transformations])

                transform_id = transformations.generate_id(row[:id])
                filename = "#{transforms_dir}/#{row[:id]}.jpg"

                if transform_id 

                    if transform_required?(filename,transform_id)

                        puts "Generating transform for #{row[:filename]}"
                        puts "Writing to #{filename} with id #{transform_id}"
                        puts transformations

                        transformations.apply(row[:filename],filename)

                        xattr = Xattr.new(filename)
                        xattr[XATTR_TRANSFORM_ID] = transform_id
                    end

                    return [ transform_id, filename ]
                end
            end
            # Ho transforms
            [ row[:id],row[:filename] ]
        end

        def map_row(row)
            row = symbolize(row)
            xattr = file_xattr(row)

            transform_id, real_file = transform(row)
            xattr[XATTR_TRANSFORM_ID] =  transform_id.to_s

            path = file_path(@events[row[:event_id]].path,row)

            options = { :exposure_time => row[:exposure_time], :event_id => row[:event_id], :xattr => xattr }
            [ real_file, path, options ]
        end

        def scan
            db.create_function("source_type",1) do |func, value|
                func.result = self.class.source_type(value)
            end

            db.create_function("source_id",1) do |func, value|
                func.result = self.class.source_id(value)
            end

            load_keywords
            load_events

            puts "Scan ##{scan_id} Finding images and photos for #{@events.size} events"
            super
            @keywords= nil
            @events = nil
        end


        # override default time handling for pathmapper 
        def times(path)
            possible_file = node(path)
            tm = possible_file ? possible_file[:exposure_time] : nil

            #set mtime and ctime to the exposure time
            return tm ? [0, tm, tm] : [0, 0, 0]
        end

        def statistics(path)
            df_path = unmap(path) || @shotwell_dir
            df = Sys::Filesystem.stat(df_path)
            stats.to_statistics(df.blocks_available * df.block_size, df.files_free)
        end

        def mounted()
            super
            start_notifier()
        end

        def unmounted()
            stop_notifier()
            super
        end


        private 

        attr_reader :events,:keywords

        def event_path(event)
            event_time = Time.at(event[:exposure_time])
            event[:name] ||= Time.at(event_time).strftime(@event_name)
            return sprintf(event_time.strftime(@event_path),event)
        end

        def event_xattr(event)
            xattr = {}
            xattr['user.shotwell.event_id'] = event[:id].to_s
            xattr['user.shotwell.event_name'] = event[:name] || ""
            xattr['user.shotwell.event_comment'] = event[:comment] || ""
            return xattr
        end

        def file_path(event_path,image)
            ext = File.extname(image[:filename]).downcase

            format = image['type'] == 'photo' ? @photo_path : @video_path

            filename = sprintf(Time.at(image[:exposure_time]).strftime(format),image)

            return "#{event_path}/#{filename}#{ext}"
        end

        def file_xattr(image)
            xattr = { }
            xattr['user.shotwell.title'] = image[:title] || ""
            xattr['user.shotwell.comment'] =  image[:comment] || ""
            xattr['user.shotwell.id'] = image[:id].to_s

            keywords = @keywords[image[:type]][image[:id]]
            xattr['user.shotwell.keywords'] = keywords.to_a.join(",") 
            xattr['user.shotwell.rating'] = image[:rating].to_s
            return xattr
        end

        def symbolize(row)
            Hash[row.map{ |k, v| [(k.respond_to?(:to_sym) ? k.to_sym : k), v] }]
        end

        def load_events
            @events = {}
            db.execute(EVENT_SQL) do |row|
                row = symbolize(row)
                id = row[:id]
                path = event_path(row)
                time = row[:exposure_time]

                xattr = event_xattr(row) 

                @events[id] = Event.new(id,path,time,xattr)
            end
        end

        def load_keywords
            @keywords = {}
            @keywords['video'] = Hash.new() { |h,k| h[k] = Set.new() }
            @keywords['photo'] = Hash.new() { |h,k| h[k] = Set.new() }

            db.execute(TAG_SQL) do |row|
                name = row['name']
                photo_list = row['photo_id_list']
                next unless photo_list
                # just use the last entry on the tag path
                slash = name.rindex('/')

                tag = slash ? name[slash+1..-1] : name
                photo_list.split(",").each do |item|
                    type = self.class.source_type(item)
                    id = self.class.source_id(item)
                    @keywords[type][id] << tag
                end
            end
            nil
        end

        def map_file(*args)
            node = super
            parent = node.parent
            unless parent[:sw_scan_id] == scan_id
                event_id = node[:event_id]
                event = @events[event_id]
                parent[:xattr] = event.xattr
                parent[:exposure_time] = event.time
                parent[:sw_scan_id] = scan_id
            end
            node
        end

        def start_notifier
            @notifier ||= INotify::Notifier.new()
            modified = false
            @notifier.watch(db_path,:modify,:close_write) do |event|
                modified = modified || event.flags.include?(:modify)
                if modified && event.flags.include?(:close_write)
                    puts "calling rescan"
                    rescan
                    puts "rescanned"
                    modified = false
                end
            end
            Thread.new { @notifier.run }
        end

        def stop_notifier
            @notifier.stop() if @notifier
        end
    end
end
