# Shotwellfs

Provides a FUSE filesystem over a Shotwell database of photos and videos (http://yorba.org/shotwell) 

## Installation

    $ gem install shotwellfs

## Usage

Start shotwellfs

    $ shotwellfs <path/to/photo.db> <mountpoint> [ -o mountoptions ]

Navigate to <mountpoint> in your favourite file browser and see your photos layed out as events

For more advanced usage see

    $shotwellfs -h

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
