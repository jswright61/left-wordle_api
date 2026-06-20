class SortedUpperStringSet
  include Enumerable

  def initialize(initial = [], req_lenth: nil, min_word_length: nil, max_word_length: nil)
    @min_word_length = req_lenth || min_word_length
    @max_word_length = req_lenth || max_word_length
    @data = []
    concat(initial)
  end

  def each(&block)
    @data.each(&block)
  end

  def <<(element)
    if element.respond_to?(:each) && !element.is_a?(String)
      element.each { |e| self << e }
    else
      normalized = element.to_s.upcase
      return self if @data.include?(normalized)
      if @min_word_length && normalized.length < @min_word_length
        raise ArgumentError.new("Words must be at least #{@min_word_length} characterslong")
      end
      if @max_word_length && normalized.length > @max_word_length
        raise ArgumentError.new("Words must be at most #{@max_word_length} characters long")
      end

      @data << normalized
      @data.sort!
    end
    self
  end

  def push(*elements)
    elements.each { |e| self << e }
    self
  end
  alias_method :append, :push
  alias_method :unshift, :push
  alias_method :prepend, :push

  def concat(other)
    push(*other)
  end

  def []=(index, value)
    raise NoMethodError.new("Indexes aren't really relevant - to delete an element just delete it by value")
  end

  def insert(_index, *values)
    push(*values)
  end

  def replace(other)
    @data.clear
    concat(other)
  end

  def to_a
    @data.dup
  end

  def to_ary
    @data.dup
  end

  def inspect
    "#<#{self.class} #{@data.inspect}>"
  end

  def method_missing(method, *args, &block)
    result = @data.send(method, *args, &block)
    normalize! if method.to_s.end_with?("!")
    result
  end

  def respond_to_missing?(method, include_private = false)
    @data.respond_to?(method, include_private)
  end

  def +(other)
    self.class.new(@data + Array(other))
  end

  private

  def normalize!
    @data.map! { |e| e.to_s.upcase }
    @data.uniq!
    @data.sort!
  end
end
