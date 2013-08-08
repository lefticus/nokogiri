ENV['RC_ARCHS'] = '' if RUBY_PLATFORM =~ /darwin/

# :stopdoc:

require 'mkmf'

RbConfig::MAKEFILE_CONFIG['CC'] = ENV['CC'] if ENV['CC']

ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))

if defined?(RUBY_ENGINE) && RUBY_ENGINE == 'macruby'
  $LIBRUBYARG_STATIC.gsub!(/-static/, '')
end

$CFLAGS << " #{ENV["CFLAGS"]}"
$LIBS << " #{ENV["LIBS"]}"

def preserving_globals
  values = [
    $arg_config,
    $CFLAGS, $CPPFLAGS,
    $LDFLAGS, $LIBPATH, $libs
  ].map(&:dup)
  yield
ensure
  $arg_config,
  $CFLAGS, $CPPFLAGS,
  $LDFLAGS, $LIBPATH, $libs =
    values
end

def asplode(lib)
  abort "-----\n#{lib} is missing.  please visit http://nokogiri.org/tutorials/installing_nokogiri.html for help with installing dependencies.\n-----"
end

def have_iconv?
  have_header('iconv.h') or return false
  %w{ iconv_open libiconv_open }.any? do |method|
    have_func(method, 'iconv.h') or
      have_library('iconv', method, 'iconv.h')
  end
end

def each_iconv_idir
  # If --with-iconv-dir or --with-opt-dir is given, it should be
  # the first priority
  %w[iconv opt].each { |config|
    idir = preserving_globals {
      dir_config(config)
    }.first and yield idir
  }

  # Try the system default
  yield "/usr/include"

  opt_header_dirs.each { |dir|
    yield dir
  }

  cflags, = preserving_globals {
    pkg_config('libiconv')
  }
  if cflags
    cflags.shellsplit.each { |arg|
      arg.sub!(/\A-I/, '') and
      yield arg
    }
  end

  nil
end

def iconv_prefix
  # Make sure libxml2 is built with iconv
  each_iconv_idir { |idir|
    prefix = %r{\A(.+)?/include\z} === idir && $1 or next
    File.exist?(File.join(idir, 'iconv.h')) or next
    preserving_globals {
      # Follow the way libxml2's configure uses a value given with
      # --with-iconv[=DIR]
      $CPPFLAGS = "-I#{idir} " << $CPPFLAGS
      $LIBPATH.unshift(File.join(prefix, "lib"))
      have_iconv?
    } and break prefix
  } or asplode "libiconv"
end

def process_recipe(name, version)
  MiniPortile.new(name, version).tap { |recipe|
    recipe.target = File.join(ROOT, "ports")
    recipe.files = ["ftp://ftp.xmlsoft.org/libxml2/#{recipe.name}-#{recipe.version}.tar.gz"]

    yield recipe

    checkpoint = "#{recipe.target}/#{recipe.name}-#{recipe.version}-#{recipe.host}.installed"
    unless File.exist?(checkpoint)
      recipe.cook
      FileUtils.touch checkpoint
    end
    recipe.activate
  }
end

windows_p = RbConfig::CONFIG['target_os'] == 'mingw32' || RbConfig::CONFIG['target_os'] =~ /mswin/

if windows_p
  $CFLAGS << " -DXP_WIN -DXP_WIN32 -DUSE_INCLUDED_VASPRINTF"
elsif RbConfig::CONFIG['target_os'] =~ /solaris/
  $CFLAGS << " -DUSE_INCLUDED_VASPRINTF"
else
  $CFLAGS << " -g -DXP_UNIX"
end

if RbConfig::MAKEFILE_CONFIG['CC'] =~ /mingw/
  $CFLAGS << " -DIN_LIBXML"
  $LIBS << " -lz" # TODO why is this necessary?
end

if RbConfig::MAKEFILE_CONFIG['CC'] =~ /gcc/
  $CFLAGS << " -O3" unless $CFLAGS[/-O\d/]
  $CFLAGS << " -Wall -Wcast-qual -Wwrite-strings -Wconversion -Wmissing-noreturn -Winline"
end

if windows_p
  message "Cross-building nokogiri.\n"

  @libdir_basename = "lib" # shrug, ruby 2.0 won't work for me.
  idir, ldir = RbConfig::CONFIG['includedir'], RbConfig::CONFIG['libdir']

  dir_config('zlib', idir, ldir)
  dir_config('xml2', [File.join(idir, "libxml2"), idir], ldir)
  dir_config('xslt', idir, ldir)
elsif arg_config('--use-system-libraries', !!ENV['NOKOGIRI_USE_SYSTEM_LIBRARIES'])
  message "Building nokogiri using system libraries.\n"

  dir_config('zlib')

  dir_config('xml2').any?  || pkg_config('libxml-2.0')
  dir_config('xslt').any?  || pkg_config('libxslt')
  dir_config('exslt').any? || pkg_config('libexslt')
else
  message "Building nokogiri using packaged libraries.\n"

  require 'mini_portile'
  require 'yaml'

  dir_config('zlib')

  dependencies = YAML.load_file(File.join(ROOT, "dependencies.yml"))

  libxml2_recipe = process_recipe("libxml2", dependencies["libxml2"]) { |recipe|
    recipe.configure_options = [
      "--enable-shared",
      "--disable-static",
      "--without-python",
      "--without-readline",
      "--with-iconv=#{iconv_prefix}",
      "--with-c14n",
      "--with-debug",
      "--with-threads"
    ]
  }

  libxslt_recipe = process_recipe("libxslt", dependencies["libxslt"]) { |recipe|
    recipe.configure_options = [
      "--enable-shared",
      "--disable-static",
      "--without-python",
      "--without-crypto",
      "--with-debug",
      "--with-libxml-prefix=#{libxml2_recipe.path}"
    ]
  }

  $LIBPATH = [libxml2_recipe, libxslt_recipe].map { |f| File.join(f.path, "lib") } | $LIBPATH
  $CPPFLAGS = ["-I#{libxml2_recipe.path}/include/libxml2", "-I#{libxslt_recipe.path}/include"].shelljoin << ' ' << $CPPFLAGS

  $CFLAGS << " -DNOKOGIRI_USE_PACKAGED_LIBRARIES -DNOKOGIRI_LIBXML2_PATH='\"#{libxml2_recipe.path}\"' -DNOKOGIRI_LIBXSLT_PATH='\"#{libxslt_recipe.path}\"'"
end

{
  "xml2"  => ['xmlParseDoc',            'libxml/parser.h'],
  "xslt"  => ['xsltParseStylesheetDoc', 'libxslt/xslt.h'],
  "exslt" => ['exsltFuncRegister',      'libexslt/exslt.h'],
}.each { |lib, (func, header)|
  have_func(func, header) || have_library(lib, func, header) or asplode("lib#{lib}")
}

unless have_func('xmlHasFeature')
  abort "-----\nThe function 'xmlHasFeature' is missing from your installation of libxml2.  Likely this means that your installed version of libxml2 is old enough that nokogiri will not work well.  To get around this problem, please upgrade your installation of libxml2.

Please visit http://nokogiri.org/tutorials/installing_nokogiri.html for more help!"
end

have_func 'xmlFirstElementChild'
have_func('xmlRelaxNGSetParserStructuredErrors')
have_func('xmlRelaxNGSetParserStructuredErrors')
have_func('xmlRelaxNGSetValidStructuredErrors')
have_func('xmlSchemaSetValidStructuredErrors')
have_func('xmlSchemaSetParserStructuredErrors')

if ENV['CPUPROFILE']
  unless find_library('profiler', 'ProfilerEnable', *LIB_DIRS)
    abort "google performance tools are not installed"
  end
end

create_makefile('nokogiri/nokogiri')

# :startdoc:
