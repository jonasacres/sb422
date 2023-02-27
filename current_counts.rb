#!/usr/bin/ruby

# Copyright (c) 2023 Jonas Acres

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'sinatra'
require 'json'

configure do
  set :protection, :except => [:json_csrf]
end

def update_results
  lines = `curl -s https://olis.oregonlegislature.gov/liz/2023R1/Measures/Testimony/SB422`.split("\n")
  return $last_results unless $?.to_i == 0

  total_testimony = lines.select { |line| line.include?("/liz/2023R1/Downloads/PublicTestimonyDocument/") }.count
  total_support   = lines.select { |line| line.include?("Support") }.count - 1
  total_oppose    = lines.select { |line| line.include?("Oppose")  }.count - 1
  total_unknown   = lines.select { |line| line.include?("Unknown") }.count

  $last_regen   = Time.at(0) if $last_results.nil? || total_testimony != $last_results[:all]
  $last_update  = Time.now
  $last_results = { all: total_testimony, support: total_support, oppose: total_oppose, unknown: total_unknown }
end

def regenerate
  lines = `curl -s https://olis.oregonlegislature.gov/liz/2023R1/Measures/Testimony/SB422`.split("\n")
  prefix = "https://olis.oregonlegislature.gov/liz/2023R1/Downloads/PublicTestimonyDocument/"
  ids = lines.map { |line| line.match(/(\/PublicTestimonyDocument\/\d+)/) }
             .compact
             .map { |match| match[1].split("/").last }
  to_download = ids.reject { |id| File.exists?("testimony/#{id}.pdf") }

  $last_update = Time.now
  return if to_download.empty?

  to_download.each do |id|
    url = prefix + id.to_s
    puts "Downloading PDF: #{url}"
    IO.write("testimony/#{id}.pdf", `curl -s #{url}`)
  end

  valid_pdfs = Dir.glob("testimony/*.pdf").select { |path| valid_pdf?(path) }.sort

  puts "Merging PDFs: #{valid_pdfs.join(" ")}"
  `pdfunite #{valid_pdfs.join(" ")} all-testimony.pdf`

  valid_pdfs.each do |path|
    puts "PDF -> TXT: #{path}"
    `pdftotext #{path}` unless File.exists?(path.gsub(".pdf", ".txt"))
  end

  txtfile = Dir.glob("testimony/*.txt").sort.map do |path|
    url = prefix + File.basename(path, ".txt")
    "===== BEGIN TESITMONY =====\n#{url}\n" + IO.read(path) + "===== END TESTIMONY =====\n"
  end.join("\n\n")

  IO.write("all-testimony.txt", txtfile)
end

def valid_pdf?(path)
  File.size(path) > 0 && IO.read(path)[0] == "%"
end

def prune_bad_testimony_files
  $last_prune = Time.now
  Dir.glob("testimony/*.pdf")
     .reject { |path| valid_pdf?(path) }
     .each   { |path| puts "Unlinking bad testimony file: #{path}" ; File.unlink(path) }
end

def needs_update?
  Time.now - $last_update > 15
end

def needs_prune?
  Time.now - $last_prune  > 60*60
end

def needs_regeneration?
  Time.now - $last_regen  >  5*60
end

Dir.mkdir("testimony") unless File.exists?("testimony")

puts "Performing initial update..."
update_results

puts "Pruning bad testimony..."
prune_bad_testimony_files

puts "Regenerating merged PDF and TXT files..."
regenerate

puts "Ready to rock and roll!"

Thread.new do
  while true
    begin
      update_results if needs_update?
      prune_bad_testimony_files if needs_prune?
      regenerate if needs_regeneration?
      sleep 0.5
    rescue Exception => exc
      STDERR.puts "Regenerate thread caught exception: #{exc.class} #{exc}\n#{exc.backtrace.join("\n")}"
    end
  end
end

get '/' do
  results = $last_results
  <<END_HTML
<html>
<head>
  <title>SB422 testimony numbers</title>
  <link href="https://fonts.googleapis.com/css?family=Press+Start+2P" rel="stylesheet">
  <link href="https://unpkg.com/nes.css/css/nes.css" rel="stylesheet" />
  <style>
    h1, h2, h3, h4, h5 {
      text-align: center;
    }

    footer p {
      text-align: center;
    }
  </style>
</head>
<body>
  <h2 class="nes-text is-primary">How many people testified for SB 422?</h1>
  <h3>(Taken fresh from <a href="https://olis.oregonlegislature.gov/liz/2023R1/Measures/Testimony/SB422">OLIS</a>!)</h3>
  
  <div class="nes-table-responsive"><table class="nes-table is-bordered is-centered" style="margin-left: auto; margin-right: auto">
    <thead>
      <th></th>
      <th></th>
    </thead>
    <tbody>
      <tr><td class="nes-text is-primary">Total</td><td><b>#{results[:all]}</b></td></tr>
      <tr><td class="nes-text is-success">Support</td><td><b>#{results[:support]}</b></td></tr>
      <tr><td class="nes-text is-error">Oppose</td><td><b>#{results[:oppose]}</b></td></tr>
      <tr><td class="nes-text is-warning">Unknown</td><td><b>#{results[:unknown]}</b></td></tr>
    </tbody>
  </table></div>

  <footer>
    <p><a href="/source">Source code</a>, <a href="/testimony.json">JSON</a>, <a href="/testimony.pdf">Big PDF</a>, <a href="/testimony.txt">Textfile</a></p>
  </footer>
</body>
</html>
END_HTML
end

get '/testimony.json' do
  content_type "application/json"
  update_results.to_json
end

get '/testimony.txt' do
  content_type "text/plain"
  IO.read("all-testimony.txt")
end

get '/testimony.pdf' do
  content_type "application/pdf"
  IO.read("all-testimony.pdf")
end

get '/source' do
  content_type "text/plain"
  IO.read(__FILE__)
end

get '/robots.txt' do
  content_type "text/plain"
  "User-agent: *\nDisallow: /"
end
