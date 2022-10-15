require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "addressable"
  gem "colorize"
  gem "commonmarker"
  gem "diff-lcs"
  gem "tty-pager"
end

require "cgi"
require "digest/sha1"
require "fileutils"
require "json"
require "open-uri"
require "pathname"
require "pp"
require "uri"
require "yaml"

require_relative("./realm")
require_relative("./markdown")

data = JSON.parse(File.read("craft.json"))

data["FolderDataModel"].each do |folder_data|
  folder = Realm::Folder.new(folder_data)
  Realm.folders[folder.id] = folder
end

data["DocumentDataModel"].each do |document_data|
  document = Realm::Document.new(document_data)
  Realm.documents[document.id] = document
end

data["BlockDataModel"].each do |block_data|
  block = Realm::Block.new(block_data)
  Realm.blocks[block.id] = block
end

# filename/attachment uniqueness
# sorted by block id so it's more stable, maybe?
attachments = {}
Realm.blocks.sort_by(&:id).each do |block|
  next unless block.block_type == :file || block.block_type == :image

  original = block.raw_properties["fileName"]
  basename = File.basename(original, ".*")
  extname = File.extname(original)

  # since extname is empty for tiff files, set it to `.png` for conversion later
  extname = ".png" if extname == ""

  if attachments[basename]
    suffix = 1
    suffix += 1 while attachments["#{basename}-#{suffix}"]
    basename = "#{basename}-#{suffix}"
  end

  attachments[basename] = block.id

  filename = basename + extname
  Realm.attachments[block.id] = Realm::Attachment.new(block.id, filename)
end

OUT = Pathname.new("out")
CRAFT = Pathname.new("craft")
FileUtils.mkdir_p(OUT)
MD.output_path = OUT

def render_markdown(input)
  CommonMarker.render_doc(input, %i[STRIKETHROUGH_DOUBLE_TILDE], %i[table tasklist strikethrough]).to_html
end

def inspect_nested_blocks(root, indent: 0)
  out = []
  root.blocks.each do |block|
    out << "#{"  " * indent}#{block.block_type} focus:#{block.focus?.inspect} #{block.raw_properties}"
    out << "#{"  " * indent}  #{block.content}"
    block.style_spans.each do |span|
      line = "#{"  " * indent}  #{" " * span.range.first}"
      line << ("^" * span.range.size)
      line << " #{span.styles.inspect} "
      line << span.range.to_s
      line << " #{span.url}" if span.styles.include?(:link)
      out << line
    end
    out << block.data if block.content.start_with?("[[") && block.block_type == :list
    out << inspect_nested_blocks(block, indent: indent + 1) if block.blocks.any?
  end
  out.join("\n")
end

db = File.exist?("converted.yaml") ? YAML.safe_load(File.read("converted.yaml")) : { "bad" => [], "good" => {}, "manual" => {} }

index = 0
documents = Realm.documents.each.to_a.sort_by(&:path)
converted = {}
while (doc = documents[index])

  if doc.path.to_s =~ /Trash/
    index +=1
    next
  end

  MD.current_document = doc

  if converted[doc.id]
    md = converted[doc.id]
  else
    puts "converting #{doc.path}"
    md = MD.convert doc.root
    path = OUT + doc.path

    begin
      FileUtils.mkdir_p path.dirname
      File.open(OUT + doc.path, "w") do |f|
        f.puts md
      end
      File.utime(doc.created_at, doc.created_at, path)
    rescue Errno::ENAMETOOLONG
      MD.warn("filename too long")
      index += 1
      next
    end

    sha = Digest::SHA1.hexdigest(md)
    db_sha = db["good"][doc.path.to_s]
    if (db_sha && db_sha == sha) || db["manual"][doc.path.to_s]
      index += 1
      next
    end
  end
  converted[doc.id] = md

  # compare results
  craft_file = CRAFT + doc.original_path
  unless File.exist?(craft_file)
    puts "missing #{craft_file}".colorize(:red)
    sleep 5
    index += 1
    next
  end

  craft = File.read(craft_file).split("\n").drop(2).join("\n") # ignore first h1 tag and newline
  File.open("/tmp/craft", "w") { |f| f.puts(craft) }
  File.open("/tmp/converted", "w") { |f| f.puts(md) }

  puts "\033[2J\033[3J\033[1;1H" # clear screen
  status = db["bad"].include?(doc.path.to_s) ? " (bad)" : ""
  output = ["----- #{doc.path} at index #{index}#{status} -----\n"]
  output << inspect_nested_blocks(doc.root) if db["bad"].include?(doc.path.to_s)

  MD.warnings[doc.path].each do |warning|
    output << warning.to_console
  end
  # output << `git --no-pager --no-ext-diff diff --ignore-space-change --color-moved-ws=ignore-all-space --word-diff=color --color=always /tmp/craft /tmp/converted`
  # output << `delta /tmp/craft /tmp/converted` # works nice when it's dark
  output << `git diff --no-ext-diff -w /tmp/craft /tmp/converted | diff-so-fancy` # better when it's light
  plaintext = `git diff --no-ext-diff --color=never /tmp/craft /tmp/converted`

  TTY::Pager.page output.join("\n")

  print "#{index+1}/#{documents.length}: q quit, y yes, x failed, m for manual review, n for next > "
  case gets.strip
  when "q"
    break
  when "y", ""
    # record it's fine
    db["good"][doc.path.to_s] = sha
    db["manual"].delete(doc.path.to_s)
    db["bad"].delete(doc.path.to_s)
    index += 1
  when "x"
    db["bad"] << doc.path.to_s
    db["manual"].delete(doc.path.to_s)
    db["good"].delete(doc.path.to_s)
    index += 1
  when "m"
    db["good"].delete(doc.path.to_s)
    db["manual"][doc.path.to_s] = plaintext
    db["bad"].delete(doc.path.to_s)
    index += 1
  when "n"
    # move to the next
    index += 1
  when "p"
    index -= 1
    index = 0 if index.negative?
  end
end

db["bad"] = db["bad"].sort.uniq
File.open("converted.yaml", "w") do |f|
  f.puts YAML.dump(db)
end

warning_text = MD.warnings.map do |path, warnings|
  "## [[#{path.basename}]]\n\n#{warnings.map(&:to_markdown).join}\n"
end.join

File.open(OUT.join("Craft Export Results.md"), "w") do |f|
  f.puts warning_text
  f.puts
  f.puts "## For manual review\n\n"
  db["manual"].each do |path, diff|
    path = Pathname.new(path)
    f.puts "## [[#{path.basename}]]"
    f.puts
    f.puts "~~~diff\n#{diff}\n~~~\n"
  end
end
