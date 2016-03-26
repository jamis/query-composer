require 'arel'

module Query
  class Base
    attr_reader :primary_table, :arel

    def initialize(primary, *args)
      @primary_table = _make_table(primary)

      @arel = Arel::SelectManager.new(ActiveRecord::Base).
        from(@primary_table)

      _configure(*args)
    end

    def reproject(*projections)
      arel.projections = projections
      self
    end

    def all
      arel.project(primary_table[Arel.star])
      self
    end

    # ensures #as returns an Arel node, and not the Query object
    # (so that it plays nice with our custom #with method, above).
    def as(name)
      arel.as(name)
    end

    def to_sql
      @arel.to_sql
    end

    alias to_s to_sql

    def method_missing(sym, *args, &block)
      arel.send(sym, *args, &block)
      self
    end

    def _make_table(value)
      case value
      when Arel::Table then value
      when Arel::Nodes::TableAlias then value
      else Arel::Table.new(value)
      end
    end

    def _configure(*args)
      # overridden by subclasses for per-query configuration
    end
  end
end
