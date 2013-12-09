require 'shotwellfs/version'
require 'rfusefs'
require 'fusefs/sqlitemapper'
require 'date'
require 'set'
require 'RMagick'
require 'digest/md5'
require 'iniparse'
require 'fileutils'
require 'ffi-xattr'

module ShotwellFS

    OPTIONS = [ :rating, :event_name, :event_path, :photo_path, :video_path ]
    OPTION_USAGE = <<-HELP

[shotwellfs]

    -o rating=N         only include photos and videos with this rating or greater (default 0)
    -o event_name=FMT   strftime format used to generate text for unnamed events (default "%d %a")
    -o event_path=FMT   strftime and sprintf format to generate path prefix for events.
                        Available event fields - id, name, comment
                        (default "%Y-%m %<name>s")
    -o photo_path=FMT   strftime and sprintf format to generate path for photo files
                        Available photo fields - id, title, comment, rating
                        (default "%<id>d")
    -o video_path=FMT  as above for video files. If not set, photo_path is used.

    HELP

    def self.main(*args)

        FuseFS.main(args,OPTIONS,OPTION_USAGE,"path/to/shotwell_dir") do |options|
            if options[:device] && File.exists?("#{options[:device]}/data/photo.db")
                FileSystem.new(options)
            else
                puts "shotwellfs: failed to access Shotwell photo database #{options[:device]}/data/photo.db"
                nil
            end
        end
    end

    def self.source_type(value)
        value.start_with?("video") ? "video" : "photo" 
    end

    def self.source_id(value)
        value[6..-1].hex 
    end


    class Transform

        attr_reader :crop,:redeye

        class RedEye
            attr_reader :eyes

            Eye = Struct.new(:x,:y,:radius) do
                def to_s()
                    "#{x},#{y}+#{radius}"
                end
            end
            

            def initialize(section)
                @eyes = []
                num_points = section['num_points'].to_i
                0.upto(num_points - 1) do |point|
                    radius = section["radius#{point}"].to_i
                    center = section["center#{point}"]
                    match = /\((\d+),\s*(\d+)\)/.match(center)
                    @eyes << Eye.new(match[1].to_i,match[2].to_i,radius)
                end
            end

            def to_s
                "RedEye(#{@eyes.join(',')})"
            end

            #convert.exe before.jpg -region "230x140+60+130" ^
            #-fill black ^
            #-fuzz 25%% ^
            #-opaque rgb("192","00","10")
            def apply(image)
                image.view(0,0,image.columns,image.rows) do |view|
                    eyes.each { |eye| do_redeye(eye,view) }
                end
            end

            # This algorithm ported directly from shotwell.
            def do_redeye(eye,pixbuf)

                #
                # we remove redeye within a circular region called the "effect
                #extent." the effect extent is inscribed within its "bounding
                #rectangle." */

                #    /* for each scanline in the top half-circle of the effect extent,
                #           compute the number of pixels by which the effect extent is inset
                #from the edges of its bounding rectangle. note that we only have
                #to do this for the first quadrant because the second quadrant's
                #insets can be derived by symmetry */
                r = eye.radius
                x_insets_first_quadrant = Array.new(eye.radius + 1)

                i = 0
                r.step(0,-1) do |y|
                    theta = Math.asin(y.to_f / r)
                    x = (r.to_f * Math.cos(theta) + 0.5).to_i
                    x_insets_first_quadrant[i] = eye.radius - x
                    i = i + 1
                end

                x_bounds_min = eye.x - eye.radius
                x_bounds_max = eye.x + eye.radius
                ymin = eye.y - eye.radius
                ymin = (ymin < 0) ? 0 : ymin
                ymax = eye.y
                ymax = (ymax > (pixbuf.height - 1)) ? (pixbuf.height - 1) : ymax

                #/* iterate over all the pixels in the top half-circle of the effect
                #extent from top to bottom */
                inset_index = 0
                ymin.upto(ymax) do |y_it|
                    xmin = x_bounds_min + x_insets_first_quadrant[inset_index]
                    xmin = (xmin < 0) ? 0 : xmin
                    xmax = x_bounds_max - x_insets_first_quadrant[inset_index]
                    xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax

                    xmin.upto(xmax) { |x_it| red_reduce_pixel(pixbuf,x_it, y_it) }
                    inset_index += 1
                end

                #/* iterate over all the pixels in the bottom half-circle of the effect
                #extent from top to bottom */
                ymin = eye.y
                ymax = eye.y + eye.radius
                inset_index = x_insets_first_quadrant.length - 1
                ymin.upto(ymax) do |y_it|
                    xmin = x_bounds_min + x_insets_first_quadrant[inset_index]
                    xmin = (xmin < 0) ? 0 : xmin
                    xmax = x_bounds_max - x_insets_first_quadrant[inset_index]
                    xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax

                    xmin.upto(xmax) { |x_it| red_reduce_pixel(pixbuf,x_it, y_it) }
                    inset_index -= 1
                end
            end

            def red_reduce_pixel(pixbuf,x,y)
                #/* Due to inaccuracies in the scaler, we can occasionally
                #* get passed a coordinate pair outside the image, causing
                #* us to walk off the array and into segfault territory.
                #    * Check coords prior to drawing to prevent this...  */
                if ((x >= 0) && (y >= 0) && (x < pixbuf.width) && (y < pixbuf.height)) 

                    #/* The pupil of the human eye has no pigment, so we expect all
                    #color channels to be of about equal intensity. This means that at
                    #any point within the effects region, the value of the red channel
                    #should be about the same as the values of the green and blue
                    #channels. So set the value of the red channel to be the mean of the
                    #values of the red and blue channels. This preserves achromatic
                    #intensity across all channels while eliminating any extraneous flare
                    #affecting the red channel only (i.e. the red-eye effect). */
                    g = pixbuf[y][x].green
                    b = pixbuf[y][x].blue
                    pixbuf[y][x].red = (g + b) / 2
                end
            end
        end

        class Crop
            attr_reader :x,:y,:width,:height
            def initialize(section)
                @x = section["left"].to_i
                @y = section["top"].to_i
                @width = section["right"].to_i - @x
                @height = section["bottom"].to_i - @y
            end

            def to_s
                "Crop(#{x},#{y},#{width},#{height})"
            end

            def apply(image)
                image.crop!(x,y,width,height)
            end
        end

        def initialize(transformations)
            doc = IniParse.parse(transformations)
            @crop = doc.has_section?("crop") ? Crop.new(doc["crop"]) : nil
            @redeye = doc.has_section?("redeye") ? RedEye.new(doc["redeye"]) : nil
        end

        def has_transforms?
            ( crop || redeye ) && true
        end

        #TODO - we need a version here. If the transform algorithm changes
        #then the cached images will need to be regenerated
        def generate_id(photo_id)
            if has_transforms?
                Digest::MD5.hexdigest("#{photo_id}:#{self}")
            else 
                nil
            end
        end

        def apply(image)
            redeye.apply(image) if redeye
            crop.apply(image) if crop
        end

        def to_s
            xforms = [ redeye, crop ].reject { |x| x.nil? }.join("\n\t")
            "#{self.class.name}:#{ShotwellFS::VERSION}\n\t#{xforms}"
        end
    end

    # A Fuse filesystem over a shotwell picture/video library
    class FileSystem < FuseFS::SqliteMapperFS

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

                if transform_id && transform_required?(filename,transform_id)

                    puts "Generating transform for #{row[:filename]}"
                    puts "Writing to #{filename} with id #{transform_id}"
                    puts transformations

                    image = Magick::Image.read(row[:filename])[0]
                    transformations.apply(image)

                    image.format = "JPG"
                    image.write(filename)
                    xattr = Xattr.new(filename)
                    xattr[XATTR_TRANSFORM_ID] = transform_id
                end

                [ transform_id, filename ]
            else
                [ row[:id],row[:filename] ]
            end
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
                func.result = ShotwellFS.source_type(value)
            end

            db.create_function("source_id",1) do |func, value|
                func.result = ShotwellFS.source_id(value)
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
                    type = ShotwellFS.source_type(item)
                    id = ShotwellFS.source_id(item)
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

    end
end
