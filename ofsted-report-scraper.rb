require 'nokogiri' # parse HTML
require 'csv'
require 'httparty' # download pages
require 'open-uri'
require 'open_uri_redirections' # Need this too, as redirect to report PDFs
require 'pdf-reader' # fastest PDF gem I've tried
require 'enumerator'
require 'ruby-progressbar'

BASE_URL = "https://reports.ofsted.gov.uk"

# Write to CSV
def write_CSV(rows, csv_path)
  headers = rows.first.keys
  csv_file = CSV.generate do |csv|
      csv << headers
      rows.each { |result| csv << result.values }
  end
  File.write(csv_path,csv_file)
  puts "  wrote #{csv_path}"
end

##
## GET LIST OF ALL SCHOOLS
##

# Download a page of results and process
# e.g. https://reports.ofsted.gov.uk/inspection-reports/find-inspection-report/results/1/any/any/any/any/any/any/any/any/any/0/0?page=13
#   -> {:name=>"The Telford Priory School", :url=>"/inspection-reports/find-inspection-report/provider/ELS/142285"...}
def process_search_results(page_num)
  doc = Nokogiri::HTML(HTTParty.get(SEARCH_PAGE_URL + page_num.to_s))
  # puts(SEARCH_PAGE_URL + page_num.to_s)
  results_list = doc.css('ul.resultsList li')
  results_array = []
  results_list.each do |result|
    result_paras = result.css('p') # split to paras
    # Find which paragraphs contain what, as not always consistent :(
    type = result_paras.find { |para| para.inner_text =~ /Provider type:/ }
    urn = result_paras.find { |para| para.inner_text =~ /URN:/ }
    local_authority = result_paras.find { |para| para.inner_text =~ /Local authority:/ }
    region = result_paras.find { |para| para.inner_text =~ /Region:/ }
    latest_report = result_paras.find { |para| para.inner_text =~ /Latest report:/ }

    result_details = {
      name: result.css('h2 a').inner_text,
      url: result.css('h2 a').attribute('href').to_s,
      address: result_paras[0] && result_paras[0].inner_text,
      urn: urn && /URN: (.+)/.match(urn.inner_text)[1],
      type: type && /Provider type: (.+)/.match(type.inner_text)[1],
      local_authority: local_authority && /Local authority: (.+)/.match(local_authority.inner_text)[1].chomp,
      region: region && /Region: (.+)/.match(region.inner_text)[1].chomp,
      latest_report: latest_report && /Latest report: (.+)/.match(latest_report.inner_text)[1].chomp,
    }
    results_array << result_details
  end
  return results_array
end

# Follow paginated results
def scrape_search_pages(first_page=0, last_page=999999)
  if last_page < 999999
    progressbar = ProgressBar.create(starting_at: first_page, total: last_page+1, format: "%a %c/%C search pages scraped: |%B|")
  else
    progressbar = ProgressBar.create(starting_at: first_page, total: nil, format: "%a %c search pages scraped: |%B|")
  end
  all_results = []
  (first_page..last_page).each do |n|
    new_results = process_search_results(n)
    if new_results.empty?
      progressbar.log "No results for page #{n}, ending search."
      break
    else
    all_results.concat(new_results)
    progressbar.increment
    sleep rand(0.1..0.6)
    end
  end
  return all_results
end

##
## GET REPORT LINKS
##

def scrape_school_page_for_reports(school)
  url = BASE_URL + school[1]
  doc = Nokogiri::HTML(HTTParty.get(url))
  reports = []
  latest_report_summary = doc.css('div.download-report-wrapper')
  latest_report_overall_effectiveness = latest_report_summary.css('#overall-effectivness span')[1] && latest_report_summary.css('#overall-effectivness span')[1].text
  report_rows = doc.css('#archive-reports tbody tr')
  report_rows.each do |report_row|
    cells = report_row.css('td')
    report_link = cells[0].css('a').attribute('href').value
    report_number = report_link.match(/\/files\/(\d+)\/urn\/\d+\.pdf$/)[1]
    report_date = cells[1].inner_text
    inspection_date = report_date.match(/(?<day>\d\d?) (?<month>\w{3}) (?<year>\d{4})/)
    inspection_date = inspection_date['year'] + '_' + inspection_date['month'] + '_' + inspection_date['day']
    school_name = school[0]
    school_urn = school[3]
    file_name = school_urn + '-' + report_number + '-' + school_name.gsub(/[^A-Za-z]/,'') + '-' + inspection_date + '.pdf'
    report_details = {
      school_name: school_name,
      school_url: school[1],
      school_urn: school_urn,
      school_latest_overall_effectiveness: latest_report_overall_effectiveness,
      report_name: cells[0].css('a').inner_text.rstrip,
      link: report_link,
      inspection_date: report_date,
      first_publication_date: cells[2].inner_text,
      school_type: school[4],
      school_region: school[6],
      pdf_file_name: file_name
    }
    reports << report_details
  end
  return reports
end

def scrape_school_pages(schools_csv)
  schools = CSV.read(schools_csv)
  schools.shift # remove header row
  progressbar = ProgressBar.create(starting_at: 0, total: schools.count, format: "%a %c/%C school pages scraped: |%B|")
  reports = []
  schools.each do |school|
    new_reports = scrape_school_page_for_reports(school)
    reports.concat(new_reports)
    progressbar.increment
    sleep rand(0.1..0.6)
  end
  return reports
end

##
## DOWNLOAD REPORTS
##

# school_name,school_url,school_urn,school_latest_overall_effectiveness,report_name,link,inspection_date,first_publication_date

def download_report_pdf(report, directory)
  report_link = report[5]
  file_name = report.last
  file_path = directory + file_name
  report_url = BASE_URL + report_link
  File.open(file_path, "wb") do |file|
    tries = 0
    begin
      open(report_url, "rb", :allow_redirections => :all) do |pdf| # Allow for silly HTTP
        file.write(pdf.read)
      end
    rescue OpenURI::HTTPError => e
      if tries < 5
        sleep tries * 5.0 + rand * 5.0
        puts "   Connection failed (#{e.message}), retrying..."
        retry 
      else
        next
      end
    end
  # progessbar.log "    Downloaded #{file_name}"
  end
end

# Download all the report pdfs from a csv of reports, filtered by year if specified, output to specified directory
def download_report_pdfs(report_csv, directory,year=nil)
  reports = CSV.read(report_csv)
  headers = reports.shift
  reports = reports.select {|report| year.nil? || report[6].match(year) } # filter by year
  files_to_download = reports.map {|report| report.last}
  total_files = files_to_download.count
  # Only select files which haven't already been [downloaded], or [downloaded, converted and deleted].
  files_to_download = files_to_download.select {|file| !(File.exist?(directory + file) || File.exist?((directory + file.gsub(/.pdf$/, ".txt"))))}
  progressbar = ProgressBar.create starting_at: total_files - files_to_download.count, total: files_to_download.count, format: "%a %e Processed: %c/%C (%P%) |%B|"
  progressbar.log "Processing #{report_csv}, #{files_to_download.count} of #{total_files} to download..."
  Dir.mkdir(directory) unless Dir.exist?(directory)
  reports.each do |report|
    report_hash = Hash[headers.zip(report)]
    next unless REPORT_TYPES.match(report_hash['report_name'])
    # puts report['school_name']
    download_report_pdf(report,directory,progressbar)
    sleep rand(1.0..2.0)
    progressbar.increment
  end
end

##
## CONVERT REPORTS
##

def convert_pdf(pdf,output_file=nil)
  output_file ||= pdf.sub(/.pdf$/, '.txt')
  if File.exist?(output_file)
    # puts "File exists, skipping..."
  else
    text = ""
    parsed_file = PDF::Reader.new(pdf)
    parsed_file.pages.each {|page| text.concat(page.text)}
    File.write(output_file, text)
    # puts "Creating .txt: #{output_file}"
  end
end

def convert_pdfs(folder)
  files = Dir.glob(folder + '*.pdf')
  # progressbar = ProgressBar.create(title: 'Files', starting_at: 0, total: files.count)
  progressbar = ProgressBar.create starting_at: 0, total: files.count, format: "%a Processed: %c/%C (%P%) |%B|"
  files.each do |file|
    begin
    convert_pdf(file) 
    progressbar.increment
    rescue PDF::Reader::MalformedPDFError
        progressbar.log "Malformed PDF: #{file}"
      next
    end
  end
end

##
## CHECK FOR 'SCIENCE' MENTIONS
##

def scan_reports(folder)
  files = Dir.glob(folder + '*.txt')
  counts = []
  files.each do |file|
    text = File.open(file, "r").read.gsub('\n','') # clear newlines introduced by PDF
    search_results = Hash.new
    KEYWORD_SEARCHES.each do |search|
      col_name = search.source + ("_mention")
      search_results[col_name] = 0
      text.scan(search) {search_results[col_name] += 1}
    end
    corrupt_pdf = text.include?('?????????')
    puts file if corrupt_pdf 
    counts.concat([{filename: file, corrupt_pdf: corrupt_pdf}.merge(search_results)])
  end
  return counts
end
