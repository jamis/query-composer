require 'test_helper'

module Query
  class WrapperTest < Minitest::Test
    def test_should_allow_arbitrary_query_to_be_used_as_a_query_object
      wrapper = Query::Wrapper.new(:people, Person.where("id=1"))
      assert_equal "SELECT \"people\".* FROM \"people\" WHERE (id=1)", wrapper.to_sql
    end
  end
end
