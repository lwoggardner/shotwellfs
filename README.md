# Shotwellfs

Provides a FUSE filesystem over a Shotwell database of photos and videos (http://yorba.org/shotwell) 

## Installation

    $ gem install shotwellfs

## Usage

Start shotwellfs

    $ shotwellfs <path/to/shotwell-dir> <mountpoint> [ -o mountoptions ]

_shotwell-dir_ is the directory containing shotwell's private data (ie data/photo.db)

Navigate to _mountpoint_ in your favourite file browser and see your photos layed out as events

   * Crop and RedEye transformations are applied to JPG and TIF images (and cached in shotwell_dir)

   * Shotwell event and photo information is available via extended attributes and thus easier to parse
     regardless of filetype

For more advanced usage, including controlling how events are mapped to directories, see

    $ shotwellfs -h

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
