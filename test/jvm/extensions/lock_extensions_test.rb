# Copyright (c) 2015 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'test_helper'

class LockExtensionsTest < Test::Unit::TestCase

	def test_synchronize_happy
    cls, = compile(<<-EOF)
      import java.util.concurrent.locks.ReentrantLock
      lock = ReentrantLock.new
      lock.synchronize do
        puts "synchronized. Yay!"
      end
    EOF
    assert_run_output("synchronized. Yay!\n", cls)
  end

  def test_synchronize_lock_unlocks_after_exception
    cls, = compile(<<-EOF)
      import java.util.concurrent.locks.ReentrantLock
      lock = ReentrantLock.new
      begin
        lock.synchronize { raise "wut" }
      rescue
      end
      Thread.new { puts lock.tryLock }.start.join
    EOF
    assert_run_output("true\n", cls)
  end
end