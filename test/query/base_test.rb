require 'test_helper'

module Query
  class BaseTest < Minitest::Test
    def test_should_interpret_symbol_argument_as_table_name
      q = Query::Base.new(:people)
      assert_equal Arel::Table.new(:people), q.primary_table
    end

    def test_should_interpret_string_argument_as_table_name
      q = Query::Base.new("people")
      assert_equal Arel::Table.new(:people), q.primary_table
    end

    def test_should_use_Arel_Table_argument_as_primary_table
      q = Query::Base.new(Arel::Table.new(:people))
      assert_equal Arel::Table.new(:people), q.primary_table
    end

    def test_should_use_Arel_Nodes_TableAlias_argument_as_primary_table
      arel = Person.all.arel.as('people')
      q = Query::Base.new(arel)
      assert_equal arel, q.primary_table
    end

    def test_should_treat_Arel_Nodes_TableAlias_as_query_source
      arel = Person.all.arel.as('folks')
      q = Query::Base.new(arel).all
      assert_equal "SELECT folks.* FROM (SELECT \"people\".* FROM \"people\") folks", q.to_sql
    end

    def test_all_should_project_all_table_attributes
      q = Query::Base.new(:people).all
      assert_match /"people"\.\*/, q.to_sql
    end

    def test_reproject_should_change_attributes_in_projection
      q = Query::Base.new(:people).all
      q.reproject(q.primary_table[:id], q.primary_table[:first_name])
      refute_match /"people"\.\*/, q.to_sql
      assert_match /"people"\."id", "people"\."first_name"/, q.to_sql
    end

    def test_as_should_return_Arel_node_instance
      q = Query::Base.new(:people).as('scooby')
      assert_instance_of Arel::Nodes::TableAlias, q
    end

    def test_to_sql_should_convert_query_to_a_string_of_SQL
      q = Query::Base.new(:people).all
      assert_equal "SELECT \"people\".* FROM \"people\"", q.to_sql
    end

    def test_unrecognized_methods_should_be_delegated_to_arel
      people = Arel::Table.new(:people)
      companies = Arel::Table.new(:companies)

      q = Query::Base.new(people).join(companies).on(people[:company_id].eq(companies[:id]))
      assert_equal "SELECT FROM \"people\" INNER JOIN \"companies\" ON \"people\".\"company_id\" = \"companies\".\"id\"", q.to_sql
    end
  end
end
