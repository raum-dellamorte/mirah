# Copyright (c) 2013 The Mirah project authors. All Rights Reserved.
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

package org.mirah.tool

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.URL
import java.net.URLClassLoader
import java.util.HashSet
import java.util.List
import java.util.logging.Logger
import java.util.logging.Level
import java.util.regex.Pattern
import javax.tools.DiagnosticListener
import mirah.impl.MirahParser
import mirah.lang.ast.CodeSource
import mirah.lang.ast.Node
import mirah.lang.ast.Script
import mirah.lang.ast.StreamCodeSource
import mirah.lang.ast.StringCodeSource
import org.mirah.IsolatedResourceLoader
import org.mirah.MirahClassLoader
import org.mirah.MirahLogFormatter
import org.mirah.jvm.compiler.Backend
import org.mirah.jvm.compiler.BytecodeConsumer
import org.mirah.jvm.compiler.JvmVersion
import org.mirah.jvm.mirrors.MirrorTypeSystem
import org.mirah.jvm.mirrors.JVMScope
import org.mirah.jvm.mirrors.ClassResourceLoader
import org.mirah.jvm.mirrors.ClassLoaderResourceLoader
import org.mirah.jvm.mirrors.FilteredResources
import org.mirah.jvm.mirrors.SafeTyper
import org.mirah.jvm.mirrors.debug.ConsoleDebugger
import org.mirah.jvm.mirrors.debug.DebuggerInterface
import org.mirah.macros.JvmBackend
import org.mirah.mmeta.BaseParser
import org.mirah.typer.simple.SimpleScoper
import org.mirah.typer.Scoper
import org.mirah.typer.Typer
import org.mirah.typer.TypeSystem
import org.mirah.util.ParserDiagnostics
import org.mirah.util.SimpleDiagnostics
import org.mirah.util.AstFormatter
import org.mirah.util.TooManyErrorsException
import org.mirah.util.LazyTypePrinter
import org.mirah.util.Context
import org.mirah.util.OptionParser

abstract class MirahTool implements BytecodeConsumer
  @@VERSION = "0.1.2.dev"

  def initialize
    reset
  end

  class CompilerArguments
    attr_accessor logger_color: boolean,
                  code_sources: List,
                  jvm_version: JvmVersion,
                  destination: String,
                  diagnostics: SimpleDiagnostics,
                  vloggers: String,
                  verbose: boolean,
                  max_errors: int
    def initialize
      @logger_color = true
      @code_sources = []
      @destination = "."

      @jvm_version = JvmVersion.new
      @classpath = nil
      @diagnostics = SimpleDiagnostics.new true
    end

    def classpath= classpath: String
      @classpath = parseClassPath(classpath)
    end

    def bootclasspath= classpath: String
      @bootclasspath = parseClassPath(classpath)
    end
    def macroclasspath= classpath: String
      @macroclasspath = parseClassPath(classpath)
    end

    def real_classpath
      @classpath ||= parseClassPath destination
      @classpath
    end

    def real_bootclasspath
      @bootclasspath
    end

    def real_macroclasspath
      @macroclasspath
    end

    def all_the_loggers
      loggers = HashSet.new
      return loggers unless vloggers

      split = vloggers.split(',')
      i = 0
      while i < split.length
        pieces = split[i].split("=", 2)
        i += 1
        vlogger = Logger.getLogger(pieces[0])
        level = Level.parse(pieces[1])
        vlogger.setLevel(level)
        loggers.add(vlogger)
      end
      loggers
    end

    def parseClassPath(classpath:String)
      filenames = classpath.split(File.pathSeparator)
      urls = URL[filenames.length]
      filenames.length.times do |i|
        urls[i] = File.new(filenames[i]).toURI.toURL
      end
      urls
    end

  end

  def self.initialize:void
    @@log = Logger.getLogger(Mirahc.class.getName)
  end

  def reset
    @compiler_args = CompilerArguments.new
  end

  def setDiagnostics(diagnostics: SimpleDiagnostics):void
    @compiler_args.diagnostics = diagnostics
  end

  def compile(args:String[]):int
    processArgs(args)

    @logger = MirahLogFormatter.new(compiler_args.logger_color).install
    if compiler_args.verbose
      @logger.setLevel(Level.FINE)
    end
    @vloggers = compiler_args.all_the_loggers

    diagnostics = @compiler_args.diagnostics

    diagnostics.setMaxErrors(@compiler_args.max_errors)

    @compiler = MirahCompiler.new(
        diagnostics,
        @compiler_args.jvm_version,
        @compiler_args.real_classpath,
        @compiler_args.real_bootclasspath,
        @compiler_args.real_macroclasspath,
        @compiler_args.destination,
        @debugger)
    parseAllFiles
    @compiler.infer
    @compiler.compile(self)
    0
  rescue TooManyErrorsException
    puts "Too many errors."
    1
  rescue CompilationFailure
    puts "#{diagnostics.errorCount} errors"
    1
  end

  def setDestination(dest:String):void
    @compiler_args.destination = dest
  end

  def destination
    @compiler_args.destination
  end

  def setClasspath(classpath:String):void
    @compiler_args.classpath = classpath
  end

  def classpath
    @compiler_args.real_classpath
  end

  def setBootClasspath(classpath:String):void
    @compiler_args.bootclasspath = classpath
  end

  def setMacroClasspath(classpath:String):void
    @compiler_args.macroclasspath = classpath
  end

  def setMaxErrors(count:int):void
    @compiler_args.max_errors = count
  end

  def setJvmVersion(version:String):void
    @compiler_args.jvm_version = JvmVersion.new(version)
  end

  def enableTypeDebugger:void
    debugger = ConsoleDebugger.new
    debugger.start
    @debugger = debugger.debugger
  end
  
  def setDebugger(debugger:DebuggerInterface):void
    @debugger = debugger
  end

  def processArgs(args:String[]):void
    compiler_args = @compiler_args

    parser = OptionParser.new("Mirahc [flags] <files or -e SCRIPT>")
    parser.addFlag(["h", "help"], "Print this help message.") do
      parser.printUsage
      System.exit(0)
    end

    parser.addFlag(
        ["e"], "CODE",
        "Compile an inline script.\n\t(The class will be named DashE)") do |c|
      compiler_args.code_sources.add(StringCodeSource.new('DashE', c))
    end

    version = @@VERSION
    parser.addFlag(['v', 'version'], 'Print the version.') do
      puts "Mirahc v#{version}"
      System.exit(0)
    end
    
    parser.addFlag(['V', 'verbose'], 'Verbose logging.') do
      compiler_args.verbose = true
    end

    parser.addFlag(
        ['vmodule'], 'logger.name=LEVEL[,...]',
        "Customized verbose logging. `logger.name` can be a class or package\n"+
        "\t(e.g. org.mirah.jvm or org.mirah.tool.Mirahc)\n"+
        "\t`LEVEL` should be one of \n"+
        "\t(SEVERE, WARNING, INFO, CONFIG, FINE, FINER FINEST)") do |spec|
      compiler_args.vloggers = spec
    end
    parser.addFlag(
        ['classpath', 'cp'], 'CLASSPATH',
        "A #{File.pathSeparator} separated list of directories, JAR \n"+
        "\tarchives, and ZIP archives to search for class files.") do |classpath|
      compiler_args.classpath = classpath
    end
    parser.addFlag(
        ['bootclasspath'], 'CLASSPATH',
        "Classpath to search for standard JRE classes."
    ) do |classpath|
      compiler_args.bootclasspath = classpath
    end
    parser.addFlag(
        ['macroclasspath'], 'CLASSPATH',
        "Classpath to use when compiling macros."
    ) do |classpath|
      compiler_args.macroclasspath = classpath
    end
    parser.addFlag(
        ['dest', 'd'], 'DESTINATION',
        'Directory where class files should be saved.'
    ) {|dest| compiler_args.destination = dest }
    parser.addFlag(['all-errors'],
        'Display all compilation errors, even if there are a lot.') {
      compiler_args.max_errors = -1
    }
    parser.addFlag(
        ['jvm'], 'VERSION',
        'Emit JVM bytecode targeting specified JVM version (1.5, 1.6, 1.7)'
    ) { |v| compiler_args.jvm_version = JvmVersion.new(v) }

    parser.addFlag(['no-color'],
      "Don't use color when writing logs"
    ) { compiler_args.logger_color = false }

    mirahc = self
    parser.addFlag(
        ['tdb'], 'Start the interactive type debugger.'
    ) { mirahc.enableTypeDebugger }

    it = parser.parse(args).iterator
    while it.hasNext
      f = File.new(String(it.next))
      addFileOrDirectory(f, compiler_args)
    end

    compiler_args
  end

  def addFileOrDirectory(f:File, compiler_args: CompilerArguments):void
    unless f.exists
      puts "No such file #{f.getPath}"
      System.exit(1)
    end
    if f.isDirectory
      f.listFiles.each do |c|
        if c.isDirectory || c.getPath.endsWith(".mirah")
          addFileOrDirectory(c, compiler_args)
        end
      end
    else
      compiler_args.code_sources.add(StreamCodeSource.new(f.getPath))
    end
  end

  def addFakeFile(name:String, code:String):void
    @compiler_args.code_sources.add(StringCodeSource.new(name, code))
  end

  def parseAllFiles
    @compiler_args.code_sources.each do |c:CodeSource|
      @compiler.parse(c)
    end
  end

  def compiler
    @compiler
  end
end