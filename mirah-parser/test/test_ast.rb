require 'test/unit'
require 'java'

$CLASSPATH << 'build/mirah-parser.jar'

class TestAst < Test::Unit::TestCase
  java_import 'mirahparser.lang.ast.VCall'
  java_import 'mirahparser.lang.ast.FunctionalCall'
  java_import 'mirahparser.lang.ast.PositionImpl'
  java_import 'mirahparser.lang.ast.StringCodeSource'
  java_import 'mirahparser.lang.ast.SimpleString'

  def test_vcall_target_has_parent
    call = VCall.new some_position
    assert_equal call, call.target.parent
  end

  def test_functional_call_target_has_parent
    call = FunctionalCall.new some_position
    assert_equal call, call.target.parent
  end

  def some_position
    PositionImpl.new(StringCodeSource.new('blah', 'codegoeshere'), 0, 0, 0, 1, 0, 1)
  end
end
