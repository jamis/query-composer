module Query
  class Wrapper < Base
    def _configure(source)
      @arel = source
    end
  end
end
