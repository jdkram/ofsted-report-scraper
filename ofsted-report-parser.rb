require 'nokogiri'
require 'csv'
require 'httparty'
require 'pry'
require 'open-uri'
require 'open_uri_redirections'
require 'pdf-reader'
require 'enumerator'

BASE_URL = "https://reports.ofsted.gov.uk"
SEARCH_PAGE_URL = "https://reports.ofsted.gov.uk/inspection-reports/find-inspection-report/results/1/any/any/any/any/any/any/any/any/any/0/0?page="
# sample_page_url = "https://reports.ofsted.gov.uk/inspection-reports/find-inspection-report/provider/ELS/126490"

# Write to CSV
def write_CSV(rows, csv_path)
  headers = rows.first.keys
  csv = CSV.generate do |csv|
      csv << headers
      rows.each { |result| csv << result.values }
  end
  File.write(csv_path,csv)
  puts "Wrote CSV to #{csv_path}"
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
    result_paras = result.css('p')
    # Find which paragraphs contain what, as not always consistent 
    urn = result_paras.find { |para| para.inner_text =~ /URN:/ }
    type = result_paras.find { |para| para.inner_text =~ /Provider type:/ }
    local_authority = result_paras.find { |para| para.inner_text =~ /Local authority:/ }
    region = result_paras.find { |para| para.inner_text =~ /Region:/ }
    latest_report = result_paras.find { |para| para.inner_text =~ /Latest report:/ }

    result_details = {
      name: result.css('h2 a').inner_text,
      url: result.css('h2 a').attribute('href').to_s,
      address: result_paras[0] && result_paras[0].inner_text,
      urn: urn && /URN: (.+)/.match(urn.inner_text)[1],
      type: type && /Provider type: (.+)/.match(type.inner_text)[1],
      local_authority: local_authority && /Local authority: (.+)/.match(local_authority.inner_text)[1],
      region: region && /Region: (.+)/.match(region.inner_text)[1],
      latest_report: latest_report && /Latest report: (.+)/.match(latest_report.inner_text)[1],
    }
    results_array << result_details
  end
  return results_array
end

# Follow paginated results
def download_search_result_pages(first_page=0, last_page=999999)
  puts "Downloading pages #{first_page} to #{last_page}"
  all_results = []
  (first_page..last_page).each do |n|
    new_results = process_search_results(n)
    if new_results.empty?
      puts "    No results for page #{n}, ending search."
      break
    else
    all_results.concat(new_results)
    puts "    Downloaded page #{n}/#{last_page}" if n % 5 == 0
    sleep 0.1
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
  latest_report_overall_effectiveness = latest_report_summary.css('#overall-effectivness span')[1].text unless latest_report_summary.css('#overall-effectivness span')[1].nil?
  # latest_report_inspection_date = latest_report_summary.css('div.donwload-report-date.inspection').css('span.ins-rep-date').text
  # latest_report_report_date = latest_report_summary.css('div.donwload-report-date.inspection').css('span.ins-rep-date')[1].text
  report_rows = doc.css('#archive-reports tbody tr')
  report_rows.each do |report_row|
    cells = report_row.css('td')
    report_details = {
      school_name: school[0],
      school_url: school[1],
      school_urn: school[3],
      school_latest_overall_effectiveness: latest_report_overall_effectiveness,
      report_name: cells[0].css('a').inner_text,
      link: cells[0].css('a').attribute('href').value,
      inspection_date: cells[1].inner_text,
      first_publication_date: cells[2].inner_text  
    }
    reports << report_details
  end
  return reports
end

def scrape_school_pages(schools_csv)
  reports = []
  CSV.foreach(schools_csv) do |school|
    next if school[0] == 'name'
    new_reports = scrape_school_page_for_reports(school)
    reports.concat(new_reports)
    puts "  Logged #{new_reports.length} link(s) for #{school[0]}"
    sleep 0.1
  end
  return reports
end

# write_CSV(download_search_result_pages(0,100),'./output/gosforth_schools2.csv')
# write_CSV(scrape_school_pages('./output/gosforth_schools2.csv'),'./output/gosforth_schools_reports2.csv')
# write_CSV(scrape_school_pages('./output/gosforth_schools.csv'),'./output/gosforth_schools_reports.csv')

##
## DOWNLOAD REPORTS
##

# school_name,school_url,school_urn,school_latest_overall_effectiveness,report_name,link,inspection_date,first_publication_date

def download_report_pdf(report, directory)
  report_school_name = report[0]
  report_school_urn = report[2]
  report_name = report[4]
  report_link = report[5]
  report_number = report_link.match(/\/files\/(\d+)\/urn\/\d+\.pdf$/)[1]
  inspection_date = report[6].match(/(?<day>\d\d?) (?<month>\w{3}) (?<year>\d{4})/)
  inspection_date = inspection_date['year'] + '_' + inspection_date['month'] + '_' + inspection_date['day']
  file_path = directory + report_school_urn + '-' + report_number + '-' + report_school_name.gsub(/[^A-Za-z]/,'') + '-' + inspection_date + '.pdf'
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
  puts "    Downloaded #{report_name+report_number} for #{report_school_name}"
  end
end

def download_report_pdfs(report_csv, directory)
  puts "Processing #{report_csv}"
  Dir.mkdir(directory) unless Dir.exist?(directory)
  CSV.foreach(report_csv) do |report|
    next unless /School inspection report/.match(report[4])
    puts report[0]
    download_report_pdf(report,directory)
    sleep 1.0 + rand
  end
end

# download_report_pdfs('./output/gosforth_schools_reports.csv','./output/pdfs/')

##
## CONVERT REPORTS
##

def convert_pdf(pdf,output_file=nil)
  parsed_file = PDF::Reader.new(pdf)
  text = ""
  parsed_file.pages.each do |page| 
    text.concat(page.text)
  end
  output_file ||= pdf.sub(/.pdf$/, '.txt')
  if File.exist?(output_file)
    # puts "File exists, skipping..."
  else
    # puts pdf
    File.write(output_file, text)
    puts "Creating .txt: #{output_file}"
  end
end

def convert_pdfs(folder)
  files = Dir.glob(folder + '*.pdf')
  files.each {|file| convert_pdf(file)}
end

##
## CHECK FOR 'SCIENCE' MENTIONS
##

def scan_reports(folder)
  files = Dir.glob(folder + '*.txt')
  counts = []
  files.each do |file|
    i,j = 0,0
    text = File.open(file, "r").read
    text.scan(/science|scientific/) {i += 1}
    text.scan(/math/) {j += 1}
    counts.concat([{filename: file, science_mentions: i, maths_mentions: j}])
  end
  return counts
end

# write_CSV(download_search_result_pages(1,250),'./output/all_schools.csv')
# write_CSV(scrape_school_pages('./output/all_schools.csv'),'./output/all_school_inspection_reports.csv')
# download_report_pdfs('./output/all_school_inspection_reports.csv','./output/all_pdfs/')
convert_pdfs('./output/all_pdfs/')
# convert_pdfs('./output/test_pdfs/')
# write_CSV(scan_reports('./output/all_pdfs/'),'./output/all_science_mentions.csv')

# download_report_pdfs('./output/gosforth_schools_reports.csv','./output/pdfs/')
# write_CSV(scan_reports('./output/pdfs/'),'./output/gosforth_science_mentions.csv')
