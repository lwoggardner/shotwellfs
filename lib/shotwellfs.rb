require 'shotwellfs/version'
require 'rfusefs'
require 'shotwellfs/filesystem'

module ShotwellFS

    OPTIONS = [ :rating, :event_name, :event_path, :photo_path, :video_path ]
    OPTION_USAGE = <<-HELP

[shotwellfs: #{VERSION}]

    -o rating=N         only include photos and videos with this rating or greater (default 0)
    -o event_name=FMT   strftime format used to generate text for unnamed events (default "%d %a")
    -o event_path=FMT   strftime and sprintf format to generate path prefix for events.
                        Available event fields - id, name, comment
                        (default "%Y-%m %<name>s")
    -o photo_path=FMT   strftime and sprintf format to generate path for photo files
                        Available photo fields - id, filename, title, comment, rating
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

end
