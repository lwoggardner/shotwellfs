# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'shotwellfs/version'

Gem::Specification.new do |gem|
  gem.name          = "shotwellfs"
  gem.version       = ShotwellFS::VERSION
  gem.authors       = ["Grant Gardner"]
  gem.email         = ["grant@lastweekend.com.au"]
  gem.description   = %q{A Fuse filesystem to remap image files according to shotwell metadata}
  gem.summary       = %q{FUSE fileystem for Shotwell}
  gem.homepage      = "http://github.com/lwoggardner/shotwellfs"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_runtime_dependency("sqlite3","~>1.3")
  gem.add_runtime_dependency("rfusefs",">=1.0.2")
  gem.add_runtime_dependency("rb-inotify","~>0.9")
  gem.add_runtime_dependency("rmagick","~>2.13")
  gem.add_runtime_dependency("iniparse","~>1.1")
  gem.add_runtime_dependency("ffi-xattr","~>0.0")
  gem.add_runtime_dependency("sys-filesystem")
  gem.add_development_dependency("yard")
  gem.add_development_dependency("redcarpet")

end
