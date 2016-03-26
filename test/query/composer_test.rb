require 'test_helper'

module Query
  class ComposerTest < Minitest::Test
    def setup
      @composer = Query::Composer.new

      @composer.use(:companies_set) { Company.all }
      @composer.use(:people_set) { Query::Wrapper.new(:people, Person.all.arel) }

      @composer.use(:joined_set) do |people_set, companies_set|
        Query::Base.new(people_set).
          project(
            people_set[:first_name].as("first_name"),
            companies_set[:name].as("name")).
          join(companies_set).
          on(people_set[:company_id].eq(companies_set[:id])).
          order(people_set[:first_name])
      end

      @composer.use(:dep_a) { |dep_b| Person.all }
      @composer.use(:dep_b) { |dep_a| Company.all }

      @composer.use(:unknown_dep) { |bogus| Person.all }
      @composer.use(:invalid_query) { 15 }
    end

    def test_composer_should_accept_ActiveRecord_scope
      results = Company.find_by_sql(@composer.build(:companies_set))
      expected = Company.all.to_a
      assert_equal(expected, results)
    end

    def test_composer_should_accept_scope_quack_alikes
      results = Person.find_by_sql(@composer.build(:people_set))
      expected = Person.all.to_a
      assert_equal(expected, results)
    end

    def test_composer_should_resolve_dependencies
      results = Person.find_by_sql(@composer.build(:joined_set))
      assert_equal(results.first.first_name, "Harry")
      assert_equal(results.first.name, "Big Company")
    end

    def test_composer_should_support_derived_tables
      results = Person.find_by_sql(@composer.build(:joined_set, use_cte: false))
      assert_equal(results.first.first_name, "Harry")
      assert_equal(results.first.name, "Big Company")
    end

    def test_composer_should_support_common_table_expressions
      results = Person.find_by_sql(@composer.build(:joined_set, use_cte: true))
      assert_equal(results.first.first_name, "Harry")
      assert_equal(results.first.name, "Big Company")
    end

    def test_composer_should_detect_circular_dependencies
      assert_raises Query::Composer::CircularDependency do
        @composer.build(:dep_a)
      end
    end

    def test_composer_should_error_when_a_dependency_isnt_recognized
      assert_raises Query::Composer::UnknownQuery do
        @composer.build(:unknown_dep)
      end
    end

    def test_composer_should_ensure_component_returns_querylike
      assert_raises Query::Composer::InvalidQuery do
        @composer.build(:invalid_query)
      end
    end

    def test_composer_use_should_overwrite_existing_component
      @composer.use(:companies_set) { Company.where("id = 1") }
      results = Company.find_by_sql(@composer.build(:companies_set))
      assert_equal 1, results.length
      assert_equal 1, results.first.id
    end

    def test_composer_alias_should_copy_named_component
      @composer.alias(:companies_again, :companies_set)
      @composer.use(:companies_set) { Company.where("id = 1") }

      results = Company.find_by_sql(@composer.build(:companies_set))
      assert_equal 1, results.length

      results = Company.find_by_sql(@composer.build(:companies_again))
      assert_equal Company.all, results
    end

    def test_composer_delete_should_remove_named_component
      @composer.delete(:companies_set)

      assert_raises Query::Composer::UnknownQuery do
        @composer.build(:companies_set)
      end
    end
  end
end
