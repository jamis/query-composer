lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "query/composer/version"

Gem::Specification.new do |gem|
  gem.version     = Query::Composer::Version::STRING
  gem.name        = "query-composer"
  gem.authors     = ["Jamis Buck"]
  gem.email       = ["jamis@jamisbuck.org"]
  gem.homepage    = "http://github.com/jamis/query-composer"
  gem.summary     = "Modularly construct complex SQL queries"
  gem.description = "Build complex SQL queries by defining each subquery separately. Query::Composer will then compose those subqueries together, nesting as needed, to produce the final SQL query."
  gem.license     = 'MIT'

  gem.files         = `git ls-files`.split($\)
  gem.test_files    = gem.files.grep(%r{^test/})
  gem.require_paths = ["lib"]

  ##
  # Development dependencies
  #
  gem.add_development_dependency "rake"
  gem.add_development_dependency "minitest"
  gem.add_development_dependency "activerecord", ">= 4.0"
  gem.add_development_dependency "rubygems-tasks", "~> 0"

  gem.add_dependency "arel", "~> 6.0"
end
