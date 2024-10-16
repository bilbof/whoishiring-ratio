require 'httparty'
require 'rainbow'
DEBUG = ENV['DEBUG'] == '1'
CACHE_FILE = "cache.json"
BUCKET_SIZE = (ENV["BUCKET_SIZE"] || 50).to_i
CHAR = ENV["CHAR"] || "█"

def posts
  puts "Fetching posts from Hacker News..." if DEBUG
  @posts ||= begin
    response = HTTParty.get('https://hacker-news.firebaseio.com/v0/user/whoishiring.json')
    submitted = JSON.parse(response.body)['submitted']
    puts submitted if DEBUG
    concurrent_fetch(submitted)
  end
end

def concurrent_fetch(submitted)
  puts "Fetching posts..." if DEBUG
  submitted.each_slice(5).map { |slice|
    Thread.new {
      slice.map { |post_id|
        puts "Fetching post #{post_id}..." if DEBUG
        response = HTTParty.get("https://hacker-news.firebaseio.com/v0/item/#{post_id}.json")
        JSON.parse(response.body)
      }
    }
  }.map(&:value).flatten
end

def cached_posts
  return JSON.parse(File.read(CACHE_FILE)) if File.exists?(CACHE_FILE)
  File.write(CACHE_FILE, JSON.dump(posts))
  posts
end

def filtered_posts(term)
  cached_posts
    .reject { |post| post['title'].nil? }
    .reject { |post| Time.at(post["time"]) < Time.new(2014,5) }
    .select { |post|
      post['title'].downcase.include?(term)
    }
    .map { |post|
      t = Time.at(post['time'])
      date = t.strftime("%Y-%m")
      {
        "title" => post["title"], "time" => post["time"], "score" => post["score"],
        "descendants" => post["descendants"], "date" => date,
      }
    }.each_with_object(Hash.new(0)) { |h, counts|
      counts["#{h['date']}"] = h['descendants']
    }
end

def job_posts
  @jobs ||= filtered_posts('hiring')
end

def job_seekers
  @seekers ||= filtered_posts('hired')
end

def ratio_over_time
  job_posts
  .to_a
  .sort_by { |year_month, _| year_month }
  .map { |year_month, count|
    job_post_count = count.to_f
    job_seeker_count = job_seekers[year_month].to_f
    val = job_post_count / job_seeker_count
    val = 0 if val.nan? || val.infinite?
    [year_month, val]
  }
end

def print_data
  ratio_over_time.each { |i, ratio| puts "#{i} #{ratio}" }
end

def plot
  height=30
  years = ratio_over_time.map { |k,_| k.split("-")[0] }.uniq.join((" " * 8))
  puts years
  max = ratio_over_time.map { |_, ratio| ratio }.max
  ratio_over_time
  .map { |i, ratio|
    char_unit = "█"
    len = (ratio / max * height).to_i
    ((char_unit * len) + (" " * (height - len))).split("")
  }
  .transpose
  .reverse
  .each { |row|
    puts row.join
  }
end

def clampn(n)
  return 0 if !n.is_a?(Numeric) || n.infinite?
  n.to_i
end

def series
  job_posts
  .to_a
  .sort_by { |year_month, _| year_month }
  .map { |year_month, count|
    [year_month, { jobs: clampn(count), seekers: clampn(job_seekers[year_month]) }]
  }
end

def plot_count(count, width, bucket_size)
  count = count / bucket_size
  width = width / bucket_size
  points = CHAR * count.to_i
  padding = " " * (width - count).to_i
  # l = points.length+padding.length
  # target = width / bucket_size
  # if l < target
  #   # puts "target:#{target}, got: #{l}, adding"
  #   padding = padding + " "
  # elsif l > target
  #   # puts "target:#{target}, got: #{l}, removing 1"
  #   padding = padding[0,padding.length]
  # end
  # puts [points.length,padding.length,points.length+padding.length].inspect
  (points + padding).split("")
rescue => e
  puts e
  puts "count = #{count}"
  puts "width = #{width}"
  puts "bucket_size = #{bucket_size}"
  raise e
end

def y_axis_tick(i, bucket_size)
  n = i * bucket_size
  s = " #{n.to_s}"
  while s.length != 5
    if s.length < 5
      s = " " + s
    else
      # unexpected but better than nothing
      return s
    end
  end
  return "#{s} "
end

def render_row(row, color: :green)
  return Rainbow(row).send(color) unless row.include?("T")
  row.split("").map { |a|
    c = a == "T" ? :orange : color
    char = a == " " ? " " : CHAR
    Rainbow(char).send(c).bright
  }.join("")
end

def add_trend(trend, i, d, type)
  return d if type == :jobs && trend[i] < 0
  return d if type == :seekers && trend[i] >= 0
  # swap out one of the bucket chars with a trend line char
  # ["#", "#", "#", "#"] => ["#", "#", "T", "#"]
  d[trend[i]] = "T"
  return d
end

def new_plot
  years = ratio_over_time.map { |k,_| k.split("-")[0] }.uniq.join((" " * 8))
  ts = series
  max_jobs = ts.map { |_, d| d[:jobs] }.max
  max_seekers = ts.map { |_, d| d[:seekers] }.max
  bucket_size = BUCKET_SIZE
  trend = ts.map { |_,d| ((((d[:jobs] - d[:seekers]) / bucket_size).round.to_f) / 2).round }
  trend_line = ts.map { |_,d| [d[:jobs]/bucket_size, d[:seekers]/bucket_size, (((d[:jobs] - d[:seekers]) / bucket_size.to_f) / 2).round] }
  job_series = ts
    .map { |_, d| plot_count(d[:jobs], max_jobs, bucket_size) }
    .map.with_index { |d, i|
      add_trend(trend, i, d, :jobs)
    }
    .transpose
    .reverse
  seeker_series = ts
    .map { |_, d| plot_count(d[:seekers], max_seekers, bucket_size).reverse }
    .map.with_index { |d, i|
      add_trend(trend, i, d, :seekers)
    }
    .transpose
    .reverse
  labels = [
    "Jobs",
    "Job seekers"
  ]

  puts ""
  puts "             " + Rainbow("Hacker News Who is Hiring: ").bright + Rainbow("Jobs Posted").bright.green + " vs " + Rainbow("Job Seekers").bright.red
  puts ""
  puts "             " + Rainbow(years).bright
  job_series[0...job_series.length-1].each_with_index { |row, i|
    pad = "       "
    tic = y_axis_tick((max_jobs / bucket_size) - i+1, bucket_size)
    dat = render_row(row.join, color: :green)
    puts Rainbow(pad + tic).green + dat
  }
  puts "        " + Rainbow(labels[0]).bright.green + " " + render_row(job_series.last.join, color: :green)
  puts " " + Rainbow(labels[1]).bright.red + " " + render_row(seeker_series.first.join, color: :red)
  seeker_series[1..].each.with_index { |row, i|
    puts Rainbow("       " + y_axis_tick(i+2, bucket_size)).red + render_row(row.join, color: :red)
  }
  puts ""
end

new_plot


# Changes:
# - negative axis
# - batch into blocks of ten, not a summary
# - add a y-axis for numbers
# - colorize jobs in green and seekers in red
