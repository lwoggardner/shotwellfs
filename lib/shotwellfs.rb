require 'shotwellfs/version'
require 'rfusefs'
require 'fusefs/sqlitemapper'
require 'date'
require 'set'

# A Fuse filesystem over a shotwell picture/video library
class ShotwellFS < FuseFS::SqliteMapperFS

    Event = Struct.new('Event', :id, :path, :time, :xattr)

    SHOTWELL_SQL = <<-SQL
        SELECT P.rating as 'rating', P.exposure_time as 'exposure_time',
               P.title as 'title', P.comment as 'comment', P.filename as 'filename', P.id as 'id',
               P.event_id as 'event_id', "photo" as 'type'
        FROM phototable P
        WHERE P.rating >= %1$d and P.event_id > 0
        UNION
        SELECT V.rating, V.exposure_time as 'exposure_time',
               V.title, V.comment, V.filename as 'filename', V.id as 'id',
               V.event_id as 'event_id', "video" as 'type'
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

        FuseFS.main(args,OPTIONS,OPTION_USAGE,"path/to/shotwell/data/photo.db") do |options|
            if options[:device] && File.exists?(options[:device])
                 self.new(options)
            else
                 puts "shotwellfs: failed to access Shotwell photo database #{options[:device]}"
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

    def initialize(options)
        shotwell_db = options[:device]

        # Default event name if it is not set - date expression based on exposure time of primary photo
        @event_name = options[:event_name] || "%d %a"

        # Event to path conversion.
        # id, name, comment
        # via event.exposure_time.strftime() and sprintf(format,event)
        @event_path = options[:event_path] || "%Y-%m %<name>s"

        # File names (without extension
        @photo_path = options[:photo_path] || "%<id>d"

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

    def map_row(row)
        row = symbolize(row)
        real_file = row[:filename]

        path = file_path(@events[row[:event_id]].path,row)

        xattr = file_xattr(row)
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
        xattr['user.event_id'] = event[:id].to_s
        xattr['user.event_name'] = event[:name]
        xattr['user.event_comment'] = event[:comment]
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
        xattr['user.title'] = image[:title]
        xattr['user.comment'] =  image[:comment]
        xattr['user.photoid'] = image[:id].to_s

        keywords = @keywords[image[:type]][image[:id]]
        keywords << "*" * image[:rating]

        xattr['user.keywords'] = keywords.to_a.join(",")
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
