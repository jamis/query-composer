require 'arel'

module Query

  # A class for composing queries into large, complicated reporting
  # monstrosities that return data for trends, histograms, and all
  # kinds of other things.
  #
  # The idea is that you first create a composer object:
  #
  #   q = Query::Composer.new
  #
  # Then, you tell the composer about a few queries:
  #
  #   q.use(:entities)  { User.all }
  #   q.use(:companies) { Company.all }
  #
  # These queries are *independent*, in that they have no dependencies.
  # But we can add some queries now that depend on those. We declare
  # another query, giving it one or more parameters. Those parameter
  # names must match the identifiers of queries given to the composer.
  # Here, we have a query that is dependent on the "entities" and
  # "companies" queries, above.
  #
  #   q.use(:entities_with_extra) do |entities, companies|
  #     team_table = Arel::Table.new(:teams)
  #
  #     Arel::SelectManager.new(ActiveRecord::Base).
  #       from(entities).
  #       project(
  #         entities[Arel.star],
  #         team_table[:name].as('team_name'),
  #         companies[:name].as('company_name')).
  #       join(team_table).
  #         on(team_table[:id].eq(entities[:team_id])).
  #       join(companies).
  #         on(companies[:id].eq(entities[:company_id]))
  #   end
  #
  # After you've defined a bunch of these queries, you should have
  # one of them (and ONLY one of them) that nothing else depends on.
  # This is the "root" query--the one that returns the data set you're
  # looking for. The composer can now do its job and accumulate and
  # aggregate all those queries together, by calling the #build method
  # with the identifier for the root query you want to build.
  #
  #   query = q.build(:some_query_identifier)
  #
  # By default, this will create a query with each component represented
  # as derived tables (nested subqueries):
  #
  #   SELECT "a".*,
  #          "b"."name" AS "company_name",
  #          "c"."name" AS "team_name"
  #     FROM (
  #       SELECT "users".* FROM "users"
  #     ) a
  #     INNER JOIN (
  #       SELECT "companies".* FROM "companies"
  #     ) b
  #     ON "b"."id" = "a"."company_id"
  #     INNER JOIN (
  #       SELECT "teams".* FROM "teams"
  #     ) c
  #     ON "c"."id" = "a"."team_id"
  #     WHERE ...
  #
  # If you would rather use CTEs (Common Table Expressions, or "with"
  # queries), you can pass ":use_cte => true" to generate the following:
  #
  #   WITH
  #     "a" AS (SELECT "users".* FROM "users"),
  #     "b" AS (SELECT "companies".* FROM "companies"),
  #     "c" AS (
  #       SELECT "a".*,
  #              "teams"."name" as "team_name",
  #              "b"."name" as "company_name"
  #         FROM "a"
  #        INNER JOIN "teams"
  #           ON "teams"."id" = "a"."team_id"
  #        INNER JOIN "b"
  #           ON "b".id = "a"."company_id")
  #     ...
  #   SELECT ...
  #     FROM ...
  #
  # Be aware, though, that some DBMS's (like Postgres) do not optimize
  # CTE's, and so the resulting queries may be very inefficient.
  #
  # If you don't want the short, opaque identifiers to be used as
  # aliases, you can pass ":use_aliases => false" to #build:
  #
  #   query = q.build(:entities_with_extra, :use_aliases => false)
  #
  # That way, the query identifiers themselves will be used as the
  # query aliases.

  class Composer
    class Error < RuntimeError; end
    class UnknownQuery < Error; end
    class CircularDependency < Error; end
    class InvalidQuery < Error; end

    @@prefer_cte = false
    @@prefer_aliases = true

    class <<self
      def prefer_cte?
        @@prefer_cte
      end

      # By default, the composer generates queries that use derived
      # tables. If you'd rather default to CTE's,
      # set Query::Composer.prefer_cte to true.
      def prefer_cte=(preference)
        @@prefer_cte = preference
      end

      def prefer_aliases?
        @@prefer_aliases
      end

      # By default, the composer generates queries that use shortened
      # names as aliases for the full names of the components. If you'd
      # rather use the full names instead of aliases, 
      def prefer_aliases=(preference)
        @@prefer_aliases = preference
      end
    end

    # Create an empty query object. If a block is given, the query
    # object will be yielded to it.
    def initialize
      @parts = {}
      yield self if block_given?
    end

    # Indicate that the named identifier should be defined by the given
    # block. The names used for the parameters of the block are significant,
    # and must exactly match the identifiers of other elements in the
    # query.
    #
    # The block should return an Arel object, for use in composing the
    # larger reporting query. If the return value of the block responds
    # to :arel, the result of that method will be returned instead.
    def use(name, &definition)
      @parts[name] = definition
      self
    end

    # Aliases the given query component with the new name. This can be
    # useful for redefining an existing component, where you still
    # want to retain the old definition.
    #
    #   composer.use(:source) { Something.all }
    #   composer.alias(:old_source, :source)
    #   composer.use(:source) { |old_source| ... }
    def alias(new_name, name)
      @parts[new_name] = @parts[name]
      self
    end

    # Removes the named component from the composer.
    def delete(name)
      @parts.delete(name)
      self
    end

    # Return an Arel object representing the query starting at the
    # component named `root`. Supported options are:
    #
    # * :use_cte (false) - the query should use common table expressions.
    #   If false, the query will use derived tables, instead.
    # * :use_aliases (true) - the query will use short, opaque identifiers
    #   for aliases. If false, the query will use the full dependency
    #   names to identify the elements.
    def build(root, options={})
      deps = _resolve(root)
      aliases = _alias_queries(deps, options)

      if _use_cte?(options)
        _query_with_cte(root, deps, aliases)
      else
        _query_with_derived_table(root, deps, aliases)
      end
    end

    def _use_cte?(options)
      options.fetch(:use_cte, self.class.prefer_cte?)
    end

    def _use_aliases?(options)
      options.fetch(:use_aliases, self.class.prefer_aliases?)
    end

    # Builds an Arel object using derived tables.
    def _query_with_derived_table(root, deps, aliases)
      queries = {}

      deps.each do |name|
        queries[name] = _invoke(name, queries).as(aliases[name].name)
      end

      _invoke(root, queries)
    end

    # Builds an Arel object using common table expressions.
    def _query_with_cte(root, deps, aliases)
      query = _invoke(root, aliases)
      components = []

      deps.each do |name|
        component = _invoke(name, aliases)
        aliased = Arel::Nodes::As.new(aliases[name], component)
        components << aliased
      end

      query.with(*components) if components.any?
      query
    end

    # Invokes the named dependency, using the given aliases mapping.
    def _invoke(name, aliases)
      block = @parts[name]
      params = block.parameters.map { |(_, name)| aliases[name] }
      result = block.call(*params)

      if result.respond_to?(:arel)
        result.arel
      elsif result.respond_to?(:to_sql)
        result
      else
        raise InvalidQuery, "query elements must quack like #arel or #to_sql (`#{name}` returned #{result.class})"
      end
    end

    # Ensure that all referenced dependencies exist in the graph.
    # Otherwise, raise Query::Composer::UnknownQuery.
    def _validate_dependencies!(name)
      raise UnknownQuery, "`#{name}`" unless @parts.key?(name)
      dependencies = []

      @parts[name].parameters.each do |(_, pname)|
        unless @parts.key?(pname)
          raise UnknownQuery, "`#{pname}` referenced by `#{name}`"
        end

        dependencies << pname
      end

      dependencies
    end

    # Resolves the tree of dependent components by traversing the graph
    # starting at `root`. Returns an array of identifiers where elements
    # later in the list depend on zero or more elements earlier in the
    # list. The resulting list includes only the dependencies of the
    # `root` element, but not the `root` element itself.
    def _resolve(root)
      _resolve2(root).flatten.uniq - [root]
    end

    # This is a utility function, used only by #_resolve. It recursively
    # tranverses the tree, depth-first, and returns a "tree" (array of
    # recursively nested arrays) representing the graph at root. The
    # root of each subtree is at the end of the corresponding array.
    #
    #   [ [ [:a], [:b], :c ], [ [:d], [:e], :f ], :root ]
    def _resolve2(root, dependents=[])
      deps = _validate_dependencies!(root)
      return [ root ] if deps.empty?

      # Circular dependency exists if anything in the dependents
      # (that which depends on root) exists in root's own dependency
      # list

      dependents = [ root, *dependents ]
      overlap = deps & dependents
      if overlap.any?
        raise CircularDependency, "#{root} -> #{overlap.join(', ')}"
      end

      all = []

      deps.each do |dep|
        all << _resolve2(dep, dependents)
      end


      all << root
    end

    # Build a mapping of dependency names, to Arel::Table objects. The
    # Arel::Table names will use opaque, short identifiers ("a", "b", etc.),
    # unless the :use_aliases option is false, when the dependency names
    # themselves will be used.
    def _alias_queries(deps, options={})
      use_aliases = _use_aliases?(options)

      aliases = {}
      current_alias = "a"

      deps.each do |key|
        if use_aliases
          aliases[key] = Arel::Table.new(current_alias)
          current_alias = current_alias.succ
        else
          aliases[key] = Arel::Table.new(key)
        end
      end

      aliases
    end
  end
end
