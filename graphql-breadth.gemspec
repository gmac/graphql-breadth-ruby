# frozen_string_literal: true

require_relative 'lib/graphql/breadth/version'

Gem::Specification.new do |spec|
  spec.name          = 'graphql-breadth'
  spec.version       = GraphQL::Breadth::VERSION
  spec.authors       = ['Greg MacWilliam']
  spec.summary       = 'A breadth-first executor for GraphQL Ruby'
  spec.description   = 'A breadth-first executor for GraphQL Ruby'
  spec.homepage      = 'https://github.com/gmac/graphql-breadth'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata    = {
    'homepage_uri' => 'https://github.com/gmac/graphql-breadth',
    'changelog_uri' => 'https://github.com/gmac/graphql-breadth/releases',
    'source_code_uri' => 'https://github.com/gmac/graphql-breadth',
    'bug_tracker_uri' => 'https://github.com/gmac/graphql-breadth/issues',
  }

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^test/})
  end
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'graphql', '>= 2.0'
  spec.add_runtime_dependency 'ostruct'

  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 12.0'
  spec.add_development_dependency 'minitest', '~> 5.12'
  spec.add_development_dependency 'async', '~> 2.0'
  spec.add_development_dependency 'benchmark-ips', '~> 2.0'
  spec.add_development_dependency 'memory_profiler'
  spec.add_development_dependency 'debug'
  spec.add_development_dependency 'graphql-batch'
  spec.add_development_dependency 'sorbet'
end
