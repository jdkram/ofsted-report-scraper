# Ofsted Report Scraper #

Download and inspect Ofsted reports for keywords. This code will:

1. Download a list of schools (`scrape_search_pages`)
2. Download a list of reports associated with those schools (`scrape_school_pages`)
3. Download a subset of those reports (`download_report_pdfs`)
4. Convert .pdf reports to .txt (`convert_pdfs`)
5. Parse .txt for keywords using regular expressions (`scan_reports`)

### Installation ###

1. `git pull https://github.com/jdkram/ofsted-report-scraper.rb`
2. `cd ofsted-report-scraper`
3. `gem install bundler`
4. `bundle install`

### Use ###

1. Modify `task.rb` - specify school types, reports types etc.
2. Run with `ruby task.rb` (or `caffeinate ruby task.rb` to keep machine awake for long downloads).

Please note that `scrape_search_pages` and `scrape_school_pages` don't currently handle being interrupted well as they don't record their progress.

`scrape_search_pages` and `scrape_school_pages` both `sleep rand(0.1..0.6)` (a random time between 0.1 and 0.6 seconds) between calls to ease the request rate on their site. `download_report_pdfs` sleeps for a slightly longer 1-2 seconds, for no particular reason other than this tends to be a large number of consecutive requests.