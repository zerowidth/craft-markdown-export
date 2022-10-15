class String
  def sanitized_path
    gsub(":", " - ").gsub("/", "-").gsub(/\s+/, " ").strip
  end
end

class Realm
  def self.folders
    @folders ||= new
  end

  def self.documents
    @documents ||= new
  end

  def self.blocks
    @blocks ||= new
  end

  # database of attachments by block ID
  def self.attachments
    @attachments ||= new
  end

  attr_reader :items

  def initialize
    @items = {}
  end

  def []=(id, item)
    items[id] = item
  end

  def [](id)
    items.fetch(id)
  end

  def get(id)
    items.fetch(id, nil)
  end

  include Enumerable
  def each(&block)
    items.values.each(&block)
  end

  # map original filenames to updated/deduplicated output filenames
  Attachment = Struct.new("Attachment", :block_id, :filename) do
    def block
      Realm.blocks[block_id]
    end
  end

  class Model
    attr_reader :data

    def self.known_keys
      []
    end

    def self.ignored_keys
      []
    end

    def self.empty_keys
      []
    end

    def initialize(data)
      all_keys = self.class.known_keys + self.class.ignored_keys + self.class.empty_keys

      raise ArgumentError, "unexpected #{self.class} keys: #{data.except(*all_keys).keys.inspect}:\n#{data}" if data.except(*all_keys).any?

      data.slice(*self.class.empty_keys).each do |key, value|
        raise ArgumentError, "unexpected #{self.class} value in empty key #{key}: #{value.inspect}:\n#{data}" unless value.empty? || value == "{}"
      end

      ignored = self.class.ignored_keys + self.class.empty_keys
      @data = data.dup.except(*ignored)
    end

    def id
      data.fetch("id")
    end
  end

  class Folder < Model
    def self.known_keys
      %w[id name parentFolderId properties documents]
    end

    def self.ignored_keys
      %w[created updated]
    end

    def self.empty_keys
      %w[offSchemaProperties]
    end

    def root?
      !parent_id
    end

    def parent_id
      data.fetch("parentFolderId", nil)
    end

    def parent
      root? ? nil : Realm.folders[parent_id]
    end

    def children
      Realm.folders.select { |f| f.data["parentFolderId"] == id }
    end

    def name
      data.fetch("name").sanitized_path
    end

    def path
      components = [name.sanitized_path]
      f = self
      while (f = f.parent)
        components.unshift f.name.sanitized_path
      end
      case components.first
      when "Daily"
        components[0] = "0 - Daily"
      when "Projects"
        components[0] = "1 - Projects"
      when "Areas"
        components[0] = "2 - Areas"
      when "Resources"
        components[0] = "3 - Resources"
      when "Archive"
        components[0] = "4 - Archive"
      end
      components.inject(Pathname.new("."), &:join)
    end

    def original_path
      components = [name]
      f = self
      while (f = f.parent)
        components.unshift f.name
      end
      p = Pathname.new(".")
      components.each { |c| p = p.join(c) }
      p
    end

    def document_ids
      data.fetch("documents")
    end

    def documents
      document_ids.map { |id| Realm.documents[id] }
    end
  end

  class Document < Model
    def self.known_keys
      %w[id rootBlockId created modified]
    end

    def self.ignored_keys
      %w[stamp syncEnabled isFetched]
    end

    def self.empty_keys
      %w[offSchemaProperties]
    end

    def root
      Realm.blocks[data.fetch("rootBlockId")]
    end

    def folder
      Realm.folders.find { |f| f.document_ids.include?(id) }
    end

    def path
      filename = "#{root.content.sanitized_path}.md"

      if filename =~ /^(\d{4}\.\d{2}\.\d{2})\.md$/
        date = Date.parse($1)
        return Pathname.new("0 - Daily") + date.strftime("%Y") + date.strftime("%Y-%m-%d %a.md")
      end

      (folder ? folder.path : Pathname.new("Inbox")) + filename
    end

    def original_path
      filename = "#{root.content}.md"
      folder ? folder.original_path + filename : Pathname.new(filename)
    end

    def subpages?
      Realm.blocks.any? { |b| b.document_id == id && !b.root? && b.blocks.any? }
    end

    def created_at
      Time.parse(data.fetch("created"))
    end

    def updated_at
      Time.parse(data.fetch("modified"))
    end

    def to_s
      "<Document #{id} #{path} #{data.inspect}>"
    end

    def inspect
      to_s
    end
  end

  class Block < Model
    def self.known_keys
      %w[id documentId content type style blocks decorations offSchemaProperties rawProperties]
    end

    def self.ignored_keys
      # pluginStyle seems irrelevant
      # pageStyleData has things like dynamic spacing and page width type
      %w[
        lastSyncedBlockIds createdByUserId modifiedByUserId
        created updated stamp pluginData pageStyleData
        isFetched lastSyncedProperties
      ]
    end

    def self.empty_keys
      %w[]
    end

    # The full set of potential raw properties for calculated block types:
    RAW_PROPERTIES = {
      ignored: [
        "coverAspectRatio",
        "coverImageBackgroundColor",
        "coverImageEnabled",
        "coverImageValueKey",
        "coverImageWidth",
        "coverUnsplashAttribution",
        "hasBeenPagifiedBefore",
      ],
      text: [
        "rawUrl",
        "dailyNoteDate",
        # not sure what scenario this is, if it's not a list too?
        "isTodoChecked",
        "toDoCheckedDate",
        # url block, or rich link, or former rich link
        "url",
        "description",
        "iconUrl",
        "title",
      ],
      heading: [
        # looks like headings can be checkboxes too, but we can ignore.
        "isTodoChecked",
        "toDoCheckedDate",
      ],
      page: [
        "coverImageEnabled",
        "dailyNoteDate",
        # cover images, can be ignored
        "coverAspectRatio",
        "coverImageBackgroundColor",
        "coverImageValueKey",
        "coverImageWidth",
        "coverUnsplashAttribution",
        # subpages in a TODO list
        "isTodoChecked",
        "toDoCheckedDate",
      ],
      list: [
        "dailyNoteDate",
        # every list item (and every other block) can be a TODO item
        "isTodoChecked",
        "toDoCheckedDate",
        "rawUrl", # ?
        "url", # can a url-only block show up as a list type?
        "description",
        "iconUrl",
        "title",
        "originalUrl"
      ],
      url: [
        # urls are standalone blocks, rather than inline link styles
        "description",
        "title",
        "url",
        "iconUrl",
        "originalUrl"
      ],
      code: [
        "language",
        "isTodoChecked",
        "toDoCheckedDate",
      ],
      file: [
        "aspectRatio",
        "altText",
        "fileName",
        "fileExtension",
        "isPreviewImageUploaded",
        "mimeType",
        "previewImageWidth",
        "primaryColor",
        "rawDataSize",
        "rawUrl", # res.craft.do url for the file itself
        "uploaded", # tracking
        "url", # also res.craft.do url
      ],
      image: [
        # mostly same as file, but marked as an image separately
        "aspectRatio",
        "altText",
        "fileName",
        "fileExtension",
        "isPreviewImageUploaded",
        "mimeType",
        "previewImageWidth",
        "previewImageHasTransparency",
        "primaryColor",
        "rawDataSize",
        "rawUrl", # res.craft.do url for the file itself
        "uploaded", # tracking
        "url", # also res.craft.do url
      ],
      separator: [],
      table: []
    }

    STYLE_PROPERTIES = {
      page: [
        "decorationStyles" # empty hash
      ],
      text: [
        "userDefinedListNumber", # customizing list start number? leftover from list?
        "decorationStyles", # empty hash
        "alignmentStyle", # left, ...
        "layoutStyle", # regular or ... (applies to links?)
        "fontStyle", # "system-serif"
      ],
      heading: [],
      code: [
        "layoutStyle", # new as of 2022-08-22
        "fontStyle", # "system-serif"
      ],
      file: [
        "imageFillStyle",
        "layoutStyle", # card or...?
      ],
      image: [
        "imageFillStyle",
        "imageSizeStyle", # auto or...?
      ],
      list: [
        "userDefinedListNumber", # customizing list start number?
        "layoutStyle", # regular or ...
        "alignmentStyle", # left, ...
        "fontStyle", # "system-serif"
      ],
      url: [
        "layoutStyle", # regular or ...?
      ],
      separator: [
        "lineStyle", # can be ignored
      ],
      table: []
    }

    def initialize(data)
      super

      validate_expected_json_keys "rawProperties", data.fetch("rawProperties"), RAW_PROPERTIES.fetch(block_type) + RAW_PROPERTIES.fetch(:ignored)
      validate_expected_json_keys "offSchemaProperties", data.fetch("offSchemaProperties"), %w[
        resourceId
        parentBlock
      ]
      validate_expected_json_keys "style", data.fetch("style"), STYLE_PROPERTIES.fetch(block_type) + %w[
        _runAttributes
        decorations
        decorationStyles
        indentationLevel
        listStyle
        textStyle
        color
      ]

      validate_expected_data "style.decorationStyles", style["decorationStyles"], [nil, {}]

      # whether it's a blockquote or not, basically:
      validate_expected_json_keys "style.decorations", style["decorations"], %w[
        focus
        block
      ]

      style.fetch("_runAttributes", []).each.with_index do |run, i|
        validate_expected_json_keys "style._runAttributes[#{i}]", run, %w[
          isBold
          isCode
          isItalic
          isStrikethrough
          linkURL
          range
          highlightColor
        ]
      end

      validate_expected_data "style.listStyle", style["listStyle"], [nil, "bullet", "numbered", "toggle", "todo", "none"]

      @data.delete "offSchemaProperties"
    end

    def block_type
      case type
      when "text"
        if list_style == :none
          case text_style
          when "body", "caption" # TODO: warn on caption?
            :text
          when "pageRegular", "pageCard"
            :page
          when "strong", "heading", "subtitle", "title"
            :heading
          else
            raise "unknown text style #{text_style}"
          end
        else
          :list
        end
      when "url"
        # these are "just" text but have their own properties rather than a style because they're standalone
        :url
      when "code"
        :code
      when "file"
        :file
      when "image"
        :image
      when "line"
        :separator
      when "table"
        :table
      else
        raise "unknown block type #{data.fetch("type")}:\n#{document.path}\n#{data.pretty_inspect}"
      end
    end

    def validate_expected_json_keys(name, data, expected_keys)
      if data.is_a? Hash
        unknown = data.except(*expected_keys)
      else
        data = "{}" if data.nil? || data.empty?
        unknown = JSON.parse(data).except(*expected_keys)
      end

      raise ArgumentError, "unexpected keys in #{self.class} #{block_type} #{name}: #{unknown.inspect}:\n#{data}" unless unknown.empty?
    end

    def validate_expected_data(name, value, expected)
      return if expected.include?(value)

      raise "unexpected #{self.class} #{name}: #{value.inspect}\n#{data.pretty_inspect}"
    end

    def document
      Realm.documents[document_id]
    end

    def document_id
      data.fetch("documentId")
    end

    def root?
      document.root.id == id
    end

    def content
      data.fetch("content")
    end

    def blocks
      data.fetch("blocks").map { |id| Realm.blocks[id] }
    end

    def type
      data.fetch("type")
    end

    def style
      @style ||= begin
        json = data.fetch("style")
        json.empty? ? {} : JSON.parse(data.fetch("style"))
      end
    end

    def style_spans
      spans = []
      style.fetch("_runAttributes", []).each do |run|
        start, length = *run.fetch("range")
        styles = []
        # replace links first, they change the content directly. the rest don't.
        styles << :link if run["linkURL"]
        styles << :code if run["isCode"]
        styles << :bold if run["isBold"]
        styles << :italic if run["isItalic"]
        styles << :strikethrough if run["isStrikethrough"]
        styles << :highlight if run["highlightColor"]
        range = start..(start + length - 1)
        spans << Span.new(range, styles, run["linkURL"])
      end
      spans
    end

    def text_style
      s = style["textStyle"] || "body"
      raise "unknown text style for #{document.path}:\n#{data}" if s.empty?

      s
    end

    def list_style
      (data["listStyle"] || style["listStyle"] || "none").to_sym
    end

    def todo_checked?
      (raw_properties["todoChecked"] || raw_properties["isTodoChecked"] || 0).to_i > 0
    end

    def indentation
      style.fetch("indentationLevel")
    end

    def decorations
      style.fetch("decorations", {})
    end

    def focus?
      decorations["focus"] || decorations["block"]
    end

    def raw_properties
      @raw_properties ||= JSON.parse(data.fetch("rawProperties"))
    end

    def to_s
      "<Block #{type} #{block_type} #{data}>"
    end

    def inspect
      to_s
    end
  end

  class Span
    attr_reader :range, :styles, :url

    def initialize(range, styles, url = nil)
      @range = range
      @styles = styles
      @url = url
    end
  end
end
