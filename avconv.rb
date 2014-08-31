# -*- coding: utf-8 -*-

module Avconv

  class FilterGraph
    attr_reader :nodes
    
    class Node
      attr_reader :inputs
      attr_reader :outputs
      attr_reader :operations
      
      def initialize(inputs,outputs = nil,&block)
        def parse_symbol(symbol)
          result = nil
          case symbol
          when Array
            result = symbol
          else
            result = [ symbol ]
          end
          return result.select {|i| i != nil }.map {|i| i.to_s }
        end
        @inputs = parse_symbol(inputs)
        @outputs = parse_symbol(outputs)
        @operations = []
        instance_eval &block if block
      end
      
      def method_missing(name, *params)
        @operations << Operation.new(name, *params)
      end
      
      def to_s
        result = ""
        result += @inputs.map {|i| "[#{i.to_s}]" }.join("")
        result += @operations.map {|i| i.to_s }.join(",")
        result += @outputs.map {|i| "[#{i.to_s}]" }.join("")
      end
    end

    class Operation
      attr_reader :name
      attr_reader :params
      def initialize(name, *params)
        @name = name.to_s
        if params.length == 1 then
          @params = params.first
        else
          @params = params
        end
      end

      def to_s
        result = "#{@name}"
        params = ""
        case @params
        when Array
          params = @params.map {|p| p.to_s }.join(":")
        when Hash
          params = []
          @params.each {|k, v| params << "#{k.to_s}=#{v.to_s}" }
          params = params.join(":")
        else
          params = @params.to_s
        end
        if params != "" then
          result +="=#{params}"
        end
        return result
      end
    end
    
    def initialize(&block)
      @nodes = []
    end
    
    def filter(params, &block)
      unless params.is_a?(Hash)
        raise ArgumentError.new("inputs => outputs must be given to the method.\n")
      end
      inputs = params.keys.first
      outputs = params.values.first
      @nodes << Node.new(inputs, outputs, &block)
    end
    
    def to_s
      return @nodes.map {|i| i.to_s }.join(";")
    end
  end
  
  class Media
    attr_accessor :path
    attr_reader   :options
    attr_accessor :stream_id

    def initialize(stream_id, path, options = nil)
      @stream_id = stream_id
      @path = path.to_s
      @options = (options && options.is_a?(Hash)) ? options : {}
    end
    
    def format(*params)
      method_missing(:format, *params)
    end
    
    def method_missing(name, *params)
      if params.length == 1 then
        @options[name.to_s] = params.first
      else
        @options[name.to_s] = params
      end
    end
    
    def __expand__(result, option, value)
      case value
      when Hash
        value.each {|id, v_for_id|
          result << "-#{option}:#{id.to_s}" << v_for_id.to_s
        }
      when Array
        value.each {|v|
          case v
          when Array
            result << "-#{option}:#{v[0]}" << v[1]
          when Hash
		    value.each {|id, v_for_id|
		      result << "-#{option}:#{id.to_s}" << v_for_id.to_s
		    }
		  else
		    ;
          end
        }
      else
        result << "-#{option}" << value.to_s
      end
    end
    
    def __translate__(options)
      result = []
      left = {}
      options.each {|k, v|
        case k.to_s
        when "force"
          result << "-y" if v
        when "conservative"
          result << "-n" if v
        when "format"
          result.insert(0, "-f", v.to_s)
        when "codec"
          __expand__(result, "codec", v)
        when "seek"
          result << "-ss" << v.to_s
        when "stats"
          result << "-stats" if v
        else
          left[k] = v
        end
      }
      return [result, left]
    end
    
    def to_a
      params,left = __translate__(@options)
      left.each {|k,v|
        case v
        when false
          ;
        when true
          params << "-#{k.to_s}"
        else
          params << "-#{k.to_s}" << v.to_s
        end
      }
      return params
    end
    
    def to_s
      result = ""
      result = @stream_id.to_s if @stream_id
      return result
    end
    
    def video(sub_stream = nil)
      return SubStream.new(self, :video, sub_stream)
    end
    
    def audio(sub_stream = nil)
      return SubStream.new(self, :audio, sub_stream)
    end
  end
  
  class SubStream
    attr_reader   :stream
    attr_accessor :media_type
    attr_accessor :sub_stream
    def initialize(stream, media_type, sub_stream = nil)
      @stream = stream
      @media_type = media_type.to_sym
      @sub_stream = sub_stream
    end
    
    def to_a
      return @stream.to_a
    end
    
    def media_spec
      case @media_type
      when :video
        return "v"
      when :audio
        return "a"
      when :title
        return "t"
      when :subtitle
      end
      return "?"
    end
    
    def to_s
      result = []
      result << @stream.to_s if @stream && @stream.to_s != ""
      result << media_spec
      result << @sub_stream if @sub_stream
      return result.join(":")
    end
  end
  
  class Source < Media
    def __translate__(options)
      results = super(options)
      left = {}
      results[1].each {|k, v|
        case k.to_s
        when "delay"
          result << "-itoffset" << v.to_s
        when "dump_attachment"
          __expand__(result, "dump_attachment", v)
        else 
          left[k] = v
        end
      }
      results[1] = left
      return results
    end
  
    def to_a
      result = super()
      result << "-i" << @path.to_s
      return result
    end
  end
  
  class Sink < Media
    def __translate__(options)
      results = super(options)
      left = {}
      results[1].each {|k, v|
        case k.to_s
        when "duration"
          result << "-t" << v.to_s
        when "limit_size"
          result << "-fs" << v.to_s
        when "frames"
          __expand__(result, "frames", v)
        when "qscale"
          __expand__(result, "qscale", v)
        when "filter"
          __expand__(result, "filter", v)
        when "attach"
          result << "-attach" << v.to_s
        else 
          left[k] = v
        end
      }
      results[1] = left
      return results
    end
  
    def to_a
      result = super()
      result << @path.to_s
      return result
    end
  end

  class BaseConverter
    attr_reader :inputs
    attr_reader :outputs

    def initialize(avconv_path="avconv")
      @inputs = []
      @outputs = []
      @avconv = avconv_path
    end
  
    def input(path, options=nil, &block)
      source = Source.new(@inputs.length, path, options)
      source.instance_eval &block if block
      @inputs << source
      return source
    end
  
    def output(path, options=nil, &block)
      sink = Sink.new(nil, path, options)
      sink.instance_eval &block if block
      @outputs << sink
      return sink
    end
    
    def filter_complex(&block)
      @filter_graph ||= FilterGraph.new
      @filter_graph.instance_eval &block if block
      return @filter_graph
    end

    def __cli_args__
      input_args = @inputs.map {|i| i.to_a }
      output_args = @outputs.map {|i| i.to_a }
      filter_args = @filter_graph ? @filter_graph.to_s : nil
      filter_args = ["-filter_complex", filter_args] if filter_args
      return [input_args, filter_args, output_args].flatten
    end
  end
  
  class Converter < BaseConverter
    attr_reader :status
    attr_reader :frame_count

    STAT_NO_PROCESS = 0
    STAT_PREPARING  = 1
    STAT_INVOKING   = 2
    STAT_CONVERTING = 3
    STAT_FINISHING  = 4
    STAT_FINISHED   = 5

    def initialize(avconv_path=nil)
      if avconv_path
        super(avconv_path)
      else
        super()
      end
      @event_handlers = {}
      reset
    end
    
    def reset
      @status = STAT_NO_PROCESS
      @frame_count = 0
    end


    def event_handlers(name)
      name = name.to_s
      @event_handlers[name] ||= []
      return @event_handlers[name]
    end
    
    def register_handler(name, &block)
      return ArgumentError.new("Block must be supplied") unless block
      event_handlers(name) << block
      return block
    end
    
    def __notify_event__(name, *params)
      handlers = event_handlers(name)
      handlers.each {|handler|
        if handler.is_a?(Proc) then
          handler.call(*params)
        end
      }
    end
    private :__notify_event__
    
    def __change_status__(new_status)
      old_status = @status
      @status = new_status
      __notify_event__(:status_changed, old_status, new_status)
    end
    private :__change_status__

    
    def x11grab(display, x_offset, y_offset, width, height, &block)
      path = "#{display}"
      if x_offset || y_offset then
        path += "+#{x_offset || 0},#{y_offset || 0}"
      end
      params = {
        :format => "x11grab",
        "s" => "#{width.to_i}x#{height.to_i}"
      }
      input(path, params, &block)
    end


    def command
      return "#{@avconv} " + __cli_args__.flatten.map {|i| (i[0] == ?-)? i:"#{i}" }.join(" ")
    end
    
    
    def run(debug = false)
      return unless @status == STAT_NO_PROCESS || @status == STAT_FINISHED

      __change_status__(STAT_INVOKING)
      rio, wio = IO.pipe
      @pid = Process.spawn(@avconv, *__cli_args__, :out => wio, :err => wio)
      wio.close

      __change_status__(STAT_PREPARING)
      $stderr.print "[AVconv]Invoking process.\n" if debug
      #frame=  186 fps= 10 q=4.0 size=     808kB time=13.40 bitrate= 493.8kbits/s
      preparation  = ""
      finalization = ""
      
      @monitor = Thread.new {

        #Invoking and preparing
        process_prepare = Proc.new do |line|
          if line =~ /Press ctrl-c to stop encoding/ then
            __change_status__(STAT_CONVERTING)
            $stderr.print "[AVconv]Start Converting.\n" if debug
          else
            preparation += line
          end
        end
        
        #Converting
        process_convert = Proc.new do |line|
          if line =~ /frame=\s*(\d+)/ then
            @frame_count = $1.to_i
          else
            __change_status__(STAT_FINISHING)
            $stderr.print "[AVconv]Finish conversion.\n" if debug
          end
        end

        #Finalization        
        process_finishing = Proc.new do |line|
          finalization += line
        end
        
        processors = {
          STAT_PREPARING  => [$/, process_prepare],
          STAT_CONVERTING => [?\r, process_convert],
          STAT_FINISHING  => [$/, process_finishing]
        }

        while true
          processor_info = processors[@status]
          if processor_info then
            delimiter, processor = processor_info
            data = rio.readline(delimiter)
            $stderr.print "[AVconv:Debug(#{@status})]#{data.chomp}\n" if debug
            processor.call(data)
          else
            data = rio.read_line($/)
            $stderr.print "[AVconv:Debug(#{@status})]#{data.chomp}\n" if debug
            break
          end
        end
        $stderr.print "[AVconv]Conversion is finished.\n" if debug
        
        Process.waitpid(@pid)
        __change_status__(STAT_FINISHIED)
        @pid = nil
      }
      return @pid
    end
    
    def stop
      if @pid then
        Process.kill(:SIGTERM, @pid)
      end
    end
    
    def wait
      @monitor.join
    end
  end

end
