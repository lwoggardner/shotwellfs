require 'RMagick'
require 'digest/md5'
require 'iniparse'
module ShotwellFS

    class Transform

        # Bump this if the transformation code changes in a way
        # that would change the images
        VERSION = 1

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

        def generate_id(photo_id)
            if has_transforms?
                Digest::MD5.hexdigest("#{photo_id}:#{self}")
            else 
                nil
            end
        end

        def apply(input,output)
            image = Magick::Image.read(input)[0]
            image.format = "JPG"

            redeye.apply(image) if redeye
            crop.apply(image) if crop

            image.write(output)
        end

        def to_s
            xforms = [ redeye, crop ].reject { |x| x.nil? }.join("\n  ")
            "#{self.class.name}:#{VERSION}\n  #{xforms}"
        end
    end
end
