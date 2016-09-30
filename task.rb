require_relative './ofsted-report-scraper.rb'

write_CSV(download_search_result_pages,'./output/all_primary_schools.csv')
write_CSV(scrape_school_pages('./output/all_primary_schools.csv'),'./output/all_primary_school_inspection_reports.csv')
download_report_pdfs('./output/all_primary_school_inspection_reports.csv','./output/all_primary_school_pdfs/','2015')
convert_pdfs('./output/all_primary_school_pdfs/')
write_CSV(scan_reports('./output/all_primary_school_pdfs/'),'./output/all_primary_school_science_mentions.csv')