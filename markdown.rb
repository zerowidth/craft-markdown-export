module MD
  HEADER_LEVELS = {
    "title" => 1,
    "subtitle" => 2,
    "heading" => 3,
    "strong" => 4
  }

  class << self
    # global output path so file attachments can be put in the right place
    attr_accessor :output_path

    # for setting global document scope during text conversion
    attr_accessor :current_document

    # hash of document path -> Warning for later rendering
    def warnings
      @warnings ||= Hash.new { |h, k| h[k] = [] }
    end

    def warn(message, details = nil)
      unless current_document
        puts "no current document: #{message}".colorize(:red)
        return
      end

      warnings[current_document.path] << Warning.new(message, details)
    end
  end

  # Converts a block and all its children to markdown
  #
  # Returns a String
  def self.convert(root)
    stack = [TextContext.new]
    current = stack.last
    blockquote = false # only have to worry about single level

    root.blocks.each do |block|
      # exit list first, since we enter it last (after blockquote)
      if current.is_a?(ListContext) && block.block_type != :list
        top = stack.pop
        current = stack.last
        current << top
      end

      if !blockquote && block.focus?
        blockquote = true
        current = BlockQuoteContext.new
        stack << current
      elsif blockquote && !block.focus?
        blockquote = false
        top = stack.pop
        current = stack.last
        current << top
      end

      case block.block_type
      when :page
        current << Header.new("#{block.content} #subpage", formatting: block.style_spans, level: 3)
        page = convert(block)
        current << Text.new(page, formatting: [])
        current << Separator.new
      when :list
        next if block.content.strip.empty?

        unless current.is_a? ListContext
          current = ListContext.new
          stack.push current
        end

        element = ListElement.new(
          block.content,
          formatting: block.style_spans,
          indent: block.indentation,
          type: block.list_style,
          checked: block.todo_checked?,
          counter: current.counter
        )
        current << element
        if block.blocks.any?
          children = convert(block)
          if block.blocks.first.block_type == :list
            current << Text.new(children, formatting: [])
          else
            children = convert(block)
            current << Header.new("#subpage", formatting: [], level: 3)
            current << Text.new(children, formatting: [])
            current << Separator.new
          end
        end
        current.increment_counter
      when :text
        next if block.content.strip.empty?

        current << Text.new(block.content, formatting: block.style_spans)
        if block.blocks.any?
          children = convert(block)
          current << Text.new(children, formatting: [])
        end
      when :heading
        level = HEADER_LEVELS[block.text_style]
        current << Header.new(block.content, level: level, formatting: block.style_spans)
        if block.blocks.any?
          children = convert(block)
          current << Text.new(children, formatting: [])
        end
      when :url
        url = block.raw_properties.fetch("url")
        raw = block.raw_properties
        description = raw["title"] || raw["description"] || url
        current << Url.new(url: url, description: description)
      when :code
        current << Code.new(block.content, language: block.raw_properties["language"])
      when :separator
        # separator is always appended to the global outer context. in craft
        # this can have an indentation, we're ignoring it
        stack.first << Separator.new
      when :file, :image
        filename = Realm.attachments[block.id].filename
        relative_path = Pathname.new("Attachments") + filename
        path = MD.output_path + relative_path
        FileUtils.mkdir_p path.dirname

        # the `url` property points to a JPEG image of the file, e.g. first page of a PDF,
        # rawUrl is the actual attachment itself
        url = block.raw_properties["rawUrl"]

        unless File.exist?(path)
          puts "downloading #{relative_path}: #{url}"
          URI.open(url) do |input|
            written = File.write("/tmp/attachment", input.read)
            expected = block.raw_properties["rawDataSize"].to_i
            diff = written - expected
            MD.warn "size mismatch in attachment #{path}: expected #{expected} got #{written}" if diff != 0
          end

          if `file /tmp/attachment`.strip =~ /TIFF/
            `convert /tmp/attachment '#{path}'`
          else
            FileUtils.mv "/tmp/attachment", path
          end
        end

        relative_path = relative_path.to_s.gsub(" ", "%20")
        current << Text.new("![#{filename}](#{relative_path})", formatting: [])
      when :table
        MD.warn("skipping table")
      else
        raise "unknown #{block.block_type}"
      end
    end

    until stack.empty?
      current = stack.pop
      stack.last << current unless stack.empty?
    end

    current.to_markdown
  end

  class Warning
    # add a warning for the current document
    # text is a string message
    # code is an optional code block with more details
    def initialize(text, code = nil)
      @text = text
      @code = code
    end

    def to_console
      out = @text.colorize(:red)
      out << "\n"
      out << @code.colorize(:yellow) << "\n" if @code
      out
    end

    def to_markdown
      md = "- [ ] #{@text}\n"
      md << "\n```\n#{@code}\n```\n\n" if @code
      md
    end
  end

  class Context
    attr_reader :children

    def initialize
      @children = []
    end

    def <<(child)
      @children << child
    end

    def to_markdown
      raise NotImplementedError
    end
  end

  class TextContext < Context
    def to_markdown
      children.map(&:to_markdown).join("\n\n")
    end
  end

  # ListContext is a collection of ListElement, each of which may have its own indentation
  class ListContext < Context
    attr_reader :counter

    def initialize(**args)
      super
      @counter = 1
    end

    def increment_counter
      @counter += 1
    end

    def to_markdown
      children.map(&:to_markdown).join("\n")
    end
  end

  class BlockQuoteContext < Context
    def to_markdown
      # join like text context, then prefix with blockquote
      children.map(&:to_markdown).join("\n\n").split("\n").map do |line|
        "> #{line}"
      end.join("\n")
    end
  end

  class Element
    attr_reader :content

    def initialize(content)
      @content = content
    end

    def to_markdown
      raise NotImplementedError
    end
  end

  class Text < Element
    attr_reader :formatting # [Realm::Span]

    def initialize(content, formatting:)
      super content
      @formatting = formatting
    end

    def formatted_content
      overlap = false
      formatting.map(&:range).sort_by(&:first).each_cons(2) do |left, right|
        if left.include?(right.first) || right.include?(left.last(1).first)
          overlap = true
          break
        end
      end

      if overlap
        skipping = "skipping overlapping styles"
        locations = content.dup
        formatting.each do |span|
          out = "\n#{" " * span.range.first}"
          out << ("^" * span.range.size)
          out << " #{span.styles.inspect} "
          out << span.range.to_s
          out << " #{span.url}" if span.styles.include?(:link)
          locations << out
        end
        MD.warn(skipping, locations)
        return content
      end

      formatting.sort_by { |span| span.range.last }.reverse.each do |span|
        prefix = ""
        substring = content[span.range]
        suffix = ""
        span.styles.each do |style|
          case style
          when :link # link always comes first
            uri = Addressable::URI.parse(span.url)

            # sometimes links are pre-rendered (in the `content`) as a markdown link.
            # if that's the case, we don't want to double it.
            next if content[span.range.first..] =~ /^\[(.+)\]\((.+)/

            # and so are block links
            next if content[span.range.first..] =~ /^\[\[(.+)\]\]/

            # link = span.url
            if substring == span.url
              # ignore, it's just an inline link and doesn't need formatting
              prefix = "["
              suffix = "](#{substring})"
            elsif uri.scheme == "day"
              prefix = "[["
              date = Date.parse(uri.host)
              substring = date.strftime("%Y-%m-%d %a")
              suffix = "]]"
            elsif uri.scheme == "craftdocs"
              block_id = uri.query_values["blockId"]
              other = Realm.blocks.get block_id

              if other.nil?
                MD.warn("skipping block link: `#{substring}` linking to nowhere")
              elsif other.root?
                prefix = "[["
                substring = other.document.path.basename.to_s.sub(/\.md$/, "")
                suffix = "]]"
              else
                MD.warn("skipping block link: `#{substring}` linking to `#{other.content}` in `#{other.document.path}`")
              end
            else
              prefix = "["
              # substring unchanged
              suffix = "](#{span.url})"
            end
          when :code
            prefix = "`#{prefix}"
            suffix << "`"
          when :highlight
            prefix = "==#{prefix}"
            suffix << "=="
          when :bold
            prefix = "**#{prefix}"
            suffix << "**"
          when :italic
            prefix = "_#{prefix}"
            suffix << "_"
          when :strikethrough
            prefix = "~~#{prefix}"
            suffix << "~~"
          else
            raise "unknown span style #{style}"
          end
        end
        content[span.range] = prefix + substring + suffix
      end
      content
    end

    def to_markdown
      formatted_content
    end
  end

  class Header < Text
    def initialize(content, level:, formatting:)
      super content, formatting: formatting
      @level = level
    end

    def to_markdown
      "#{"#" * @level} #{formatted_content}"
    end
  end

  class ListElement < Text
    attr_reader :indent, :type, :checked, :counter

    # needs common text styling, same as text
    def initialize(content, indent:, type:, formatting:, checked:, counter:)
      super content, formatting: formatting
      @indent = indent
      @type = type
      @checked = checked
      @counter = counter
    end

    def to_markdown
      marker = (type == :numbered ? "#{counter}." : "-")
      fill = checked ? "x" : " "
      check = type == :todo ? " [#{fill}]" : ""
      "#{" " * indent * 4}#{marker}#{check} #{formatted_content}"
    end
  end

  class Code < Element
    attr_reader :language

    def initialize(content, language:)
      super content
      @language = language unless language == "other"
    end

    def to_markdown
      "```#{language}\n#{content}\n```"
    end
  end

  class Url
    attr_reader :url, :description

    def initialize(url:, description:)
      @url = url
      @description = description
    end

    def to_markdown
      "[#{description}](#{url})"
    end
  end

  class Separator
    def to_markdown
      "---"
    end
  end
end
