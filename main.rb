require 'httparty'

DEBUG = ENV['DEBUG'] == '1'

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

def filtered_posts(term)
  posts
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

puts "Lets-a go!"
plot
