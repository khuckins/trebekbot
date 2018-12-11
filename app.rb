# encoding: utf-8
require "sinatra"
require "json"
require "httparty"
require "redis"
require "dotenv"
require "text"
require "sanitize"
require "date"
require 'concurrent'
require 'rest-client'

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true

  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV["LOCAL_REDIS_URL"])
  when :production
    uri = URI.parse(ENV["REDISCLOUD_URL"])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

# Handles the POST request made by the Slack Outgoing webhook
# Params sent in the request:
#
# token=abc123
# team_id=T0001
# channel_id=C123456
# channel_name=test
# timestamp=1355517523.000005
# user_id=U123456
# user_name=Steve
# text=trebekbot jeopardy me
# trigger_word=trebekbot
#
post "/" do
  begin
    params[:text] = params[:text].sub(params[:trigger_word], "").strip
    if params[:token] != ENV["OUTGOING_WEBHOOK_TOKEN"]
      response = "Invalid token"
    elsif is_channel_blacklisted?(params[:channel_name])
      response = "Sorry, can't play in this channel."
    elsif params[:text].match(/^jeopardy me/i)
      response = respond_with_question(params, nil, nil, true)
    elsif params[:text].match(/my score$/i)
      response = respond_with_user_score(params[:user_id], params[:user_name])
    elsif params[:text].match(/^end game/i)
      response = clear_leaderboard
    elsif params[:text].match(/^help$/i)
      response = respond_with_help
    elsif params[:text].match(/^show (me\s+)?(the\s+)?leaderboard$/i)
      response = respond_with_leaderboard()
    elsif params[:text].match(/^show (me\s+)?(the\s+)?loserboard$/i)
      response = respond_with_leaderboard("loserboard:1", "asc", "bottom")
    elsif params[:text].match(/^show (me\s+)?(the\s+)?categories$/i)
      response = respond_with_categories(params)
    elsif params[:text].match(/^let's play$/i)
      response = respond_with_categories(params)
    elsif matches = params[:text].match(/^I'll take (.*) for (.*)/i)
      response = respond_with_question(params, matches[1], matches[2])
    elsif params[:text].match(/^Throw (.*) at (.*)/i)
      response = "Do I look like zorkbot?"
    elsif matches = params[:text].match(/^I wager (.*)/i)
      response = respond_with_final_jeopardy_wager(params, matches[1])
    else
      response = process_answer(params)
    end
  rescue => e
    puts "[ERROR] #{e}"
    response = ""
  end
  status 200
  body json_response_for_slack(response)
end

def logger(method, str)
  puts "[#{method}] #{str}"
end

# Puts together the json payload that needs to be sent back to Slack
#
def json_response_for_slack(reply)
  response = { text: reply, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  response.to_json
end

def send_reply_to_slack(channel_id, text)
  payload = {}
  payload["channel_id"] = channel_id
  payload["text"] = text
  payload["username"] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  payload["icon_emoji"] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  if !ENV["SLACK_INCOMING_URI"].nil?
    RestClient.post ENV["SLACK_INCOMING_URI"], payload.to_json, :content_type => :json, :accept => :json
  end
end

# Determines if a game of Jeopardy is allowed in the given channel
#
def is_channel_blacklisted?(channel_name)
  !ENV["CHANNEL_BLACKLIST"].nil? && ENV["CHANNEL_BLACKLIST"].split(",").find{ |a| a.gsub("#", "").strip == channel_name }
end

# Puts together the response to a request to start a new round (`jeopardy me`):
# If the bot has been "shushed", says nothing.
# Otherwise, speaks the answer to the previous round (if any),
# speaks the category, value, and the new question, and shushes the bot for 5 seconds
# (this is so two or more users can't do `jeopardy me` within 5 seconds of each other.)
#
def respond_with_question(params, category = nil, value = nil, random_question = nil)
  channel_id = params[:channel_id]
  key = "current_question:#{channel_id}"
  catkey = "current_categories:#{channel_id}" # We'll need to match the categories
  question = ""
  unless $redis.exists("shush:question:#{channel_id}")
    if rand.nil?
      if value.nil?
        return "Typically, you would want to select a question on the board, not just a category."
      elsif category.nil?
        return "And what question in what category would you like me to ask?"
      else
        cat_response = compare_category(catkey, category)
        return "That category isn't on the board." if cat_response == false
        val_response = compare_value(catkey, category, value)
        return "That question is no longer on the board." if val_response == false
      end
    end
    unless $redis.exists("triggered_dd:#{channel_id}")
      rand > ENV["DD_CHANCE"].to_i ? dd = false : dd = true
    end
    question = handle_question_retrieval(channel_id, key, catkey, category, value, random_question, dd)
  end
  question
end

def validate_random_question(params)
  if ENV["ENABLE_RANDOM_QUESTIONS"] == true
    response = respond_with_question(params, nil, nil, true)
  else
      response = respond_with_categories(params)
  end
end

# Once the categories are exhausted and all questions are answered, trebekbot
# looks at all the players with scores higher than $1, asks them to wager.
# Trebekbot will ask each individual a separate question only they can answer,
# awarding them with the score wagered if correct
def respond_with_final_jeopardy_intro(channel_id)
  prev_question_key = "current_question:#{channel_id}"
  unless $redis.exists("shush:question:#{channel_id}")

    #Get finalists
    finalists = parse_score_leaders()
    final_category = fetch_categories(1)
    $redis.set("final_category:#{channel_id}", final_category[0].to_json)
    if finalists.size < 1
      response = clear_leaderboard()
    else
      finalist_strings = []
      finalists.each do |finalist|
        finalist_strings.push("#{finalist[:user_name]}, with #{currency_format(finalist[:score].to_i)}")
        $redis.del("finalist_answer:#{finalist[:user_id]}") if $redis.exists("finalist_answer:#{finalist[:user_id]}")
        $redis.set("finalist:#{finalist[:user_id]}", finalist.to_json)
        $redis.set("finalist_wager:#{finalist[:user_id]}", nil)
      end
      response = "Before we get into Final Jeopardy!, I want to take this opportunity to thank Slack for its hospitality, as well as our friends at #random.\n"
      response += "Now, let's take a look at our finalists. We have " + finalist_strings.join("`; `") + ". \n"
      response += "Remember, this could have the possibility of a big win happening for any of our finalists. \n"
      response += "The final Jeopardy! category is `#{final_category[0]['title']}`. \n"
      response += "Finalists, once everyone submits their wager using `trebekbot I wager [VALUE]`, I will provide the clue."
    end
    response
  end
end

def respond_with_final_jeopardy_wager(params, wager)
  channel_id = params[:channel_id]
  user_id = params[:user_id]
  user_nick = params[:user_name]

  # Rule out some major problems immediately
  return "We are not in Final Jeopardy!, #{user_nick}." if !$redis.exists("final_category:#{channel_id}")
  return "You are not a finalist, #{user_nick}." if !$redis.exists("finalist:#{user_id}")
  #return "You have already made your bet, #{user_nick}. You cannot change it." if $redis.exists("finalist_wager:#{user_id}")

  player = $redis.get("finalist:#{user_id}")
  player_score = get_user_score(user_id)
  if validate_wager(wager, player_score) == false
    return "Try again, #{user_nick}. You may wager between #{currency_format(1)} up to your current score, #{currency_format(player_score)}."
  end
  $redis.set("finalist_wager:#{user_id}", wager)
  response = "You're wagering #{currency_format(wager.to_i)}, #{user_nick}."

  if has_everyone_wagered() == true
    response += respond_with_final_jeopardy_question(channel_id)
  end
  response
end

def respond_with_final_jeopardy_question(channel_id)
  uri_key = "final_category:#{channel_id}"
  final_category = JSON.parse($redis.get(uri_key))
  uri = gather_uri(uri_key, final_category['title'])
  final_question = fetch_question(uri)
  set_current_question(channel_id, "current_question:#{channel_id}", final_question)

  date = Date.parse(final_question["airdate"])
  response = "Now that everyone has placed their wager, today's Final Jeopardy! question is, from `#{date.strftime("%Y")}`: `#{final_question["question"]}` \n"
  response += "You have #{ENV["SECONDS_TO_ANSWER"]} seconds, players, good luck."

  response
end

def validate_wager(wager, score)
  return wager.to_i <= score.to_i && wager.to_i > 0
end

def has_everyone_wagered
  b = true

  finalists = parse_score_leaders()
  finalists.each do |finalist|
    if !$redis.exists("finalist_wager:#{finalist[:user_id]}")
      b = false
    end
  end
  b
end

def handle_question_retrieval(channel_id, key, catkey, category, value, random_question, dd = nil)
  uri = gather_uri(catkey, category, value)
  response = fetch_question(uri)
  question = ""
  unless !random_question.nil?
    remove_val_from_category(catkey, category, value, channel_id)
  end
  previous_question = $redis.get(key)
  if !previous_question.nil?
    previous_question = JSON.parse(previous_question)["answer"]
    question = "The answer is `#{previous_question}`.\n"
  end
  if dd
    question += "Daily Double!\n"
    $redis.set("triggered_dd:#{channel_id}", true)
    response["value"] = response["value"] * 2
  end
  date = Date.parse(response["airdate"])
  question += "The category is `#{response["category"]["title"]}` for #{currency_format(response["value"])}, from `#{date.strftime("%Y")}`: `#{response["question"]}`"
  set_current_question(channel_id, key, response)
  start_timer(channel_id, response)
  question
end

def set_current_question(channel_id, key, response)
  $redis.pipelined do
    $redis.set(key, response.to_json)
    $redis.setex("shush:question:#{channel_id}", 10, "true")
    $redis.set("category:#{response['category']['title']}", "#{response['category'].to_json}")
  end
end

def compare_category(key, category)
  categories = return_categories(key)
  match = false
  category_titles = return_cat_data(categories, 'title')

  category_titles.each do |title|
    if (title == category)
      match = true
    end
  end
  match
end

def compare_value(key, cat, val)
  category = return_categories(key).select {|c| c['title'] == cat}[0]
  match = false

  category['values'].each do |value|
    if (val == value)
      match = true
    end
  end
  match
end

# Creates the URI based on user request
def gather_uri(key = nil, cat = nil, val = nil)
  uri = "http://jservice.io/api/"
  if !key.nil? && !cat.nil?
    category = return_categories(key)
    category = category.select {|c| c["title"] == cat}[0] if category.kind_of? Array
    uri += "clues?category=#{category['id']}"
    if !val.nil?
      uri += "&value=#{val}"
    end
  else
    uri += "random?count=1"
  end
  uri
end

# Fetches question using URI
def fetch_question(uri)
  request = HTTParty.get(uri)
  response = JSON.parse(request.body).first
  question = response["question"]
  if validate_question(question)
    response = "Surprise Round! Instead of the question you were expecting, we'll ask you this. \n"
    new_uri = gather_uri()
    response += fetch_question(new_uri)
  end
  response = sanitize_question_response(response)
  response
end

# Ensures question exists and doesn't contain blacklisted substrings
def validate_question(question)
  return question.nil? || question.strip == "" || (!ENV["QUESTION_SUBSTRING_BLACKLIST"].nil? && ENV["QUESTION_SUBSTRING_BLACKLIST"].split(',').any? { |phrase| question.include?(phrase) })
end

# If the answer doesn't have a value, sets a default of $200
# If there's HTML in the answer, sanitizes it (otherwise it won't match the user answer)
# Adds an "expiration" value, which is the timestamp of the Slack request + the seconds to answer config var
def sanitize_question_response(response)
  response["value"] = 200 if response["value"].nil?
  response["answer"] = Sanitize.fragment(response["answer"].gsub(/\s+(&nbsp;|&)\s+/i, " and "))
  response["expiration"] = params["timestamp"].to_f + ENV["SECONDS_TO_ANSWER"].to_f
  response
end

## Category Retrieval
# Fetches new categories to populate current_categories
def fetch_categories(count = ENV['DEFAULT_CATEGORY_COUNT'].to_i)
  max_category = 18418
  uri = "http://jservice.io/api/categories?count=#{count}&offset=#{1+rand(max_category/count.to_f)}"
  request = HTTParty.get(uri)
  data = JSON.parse(request.body)
end

def start_timer(channel_id, response)
  Concurrent::ScheduledTask.execute(ENV["SECONDS_TO_ANSWER"]){ end_round(channel_id, response) }
end

def end_round(channel_id, response)
  # make sure the current question is the same one we were waiting for
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  current_question = JSON.parse(current_question)
  if response["id"] == current_question["id"]
    reply = "Time's up! The correct answer is `#{current_question["answer"]}`."
    send_reply_to_slack(channel_id, reply)
    mark_question_as_answered(channel_id)
    check_final_jeopardy_valid(channel_id)
  end
end

def check_final_jeopardy_valid(channel_id)
  if $redis.exists("begin_final_jeopardy:#{channel_id}")
    res = respond_with_final_jeopardy_intro(channel_id)
    send_reply_to_slack(channel_id, res)
  end
end

# Returns existing categories or generates new ones
def return_categories(key)
  if $redis.exists(key)
    categories = JSON.parse($redis.get(key))
    categories
  else
    data = fetch_categories()
    current_categories = []
    data.each do |child|
      add_category(key, child, current_categories)
    end
    return_categories(key)
  end
end

# Returns array of specific category data(useful for titles)
def return_cat_data(categories, data)
  category_data = []
  categories.each do |category|
    category_data.push(category["#{data}"])
  end
  category_data
end

# Responds with the current categories, if available. Otherwise, fetches a new
# set of categories.
def respond_with_categories(params)
  channel_id = params[:channel_id]
  key = "current_categories:#{channel_id}"
  categories = return_categories(key)
  response = stringify_remaining_questions(categories)
  response
end

def stringify_remaining_questions(categories)
  response = "Wonderful. Let's take a look at the categories. They are: \n"
  category_titles = return_cat_data(categories, 'title')
  categories.each do |category|
    response += "`" + category['title'] + "` for `" + category['values'].join("`, `") + "`.\n"
  end
  response
end

# Adds categories to current_categories. Category data consists of:
# ID - The ID of the category, for ease of lookup later
# Title - The title of the category, for player input
# Values - 100-1000. These should be removed as questions on the board are
# taken.
def add_category(key = nil, base_category = nil, current_categories = nil)
  base_category['title'] = sanitize_titles(base_category['title'])
  if !base_category.nil?
    category = {
      'id' => base_category['id'],
      'title' => base_category['title'],
      'values' => value_set,
      'clues_count' => base_category['clues_count'].to_s
    }
    current_categories.push(category)
    $redis.set(key, current_categories.to_json)
  else
    logger(__method__, "No category specified")
  end
end

def sanitize_titles(title)
  sanitized_title = title.gsub /&amp;/, "and"
  sanitized_title
end

def remove_category(key = nil, rcategory = nil, channel_id)
  response = ""
  if !$redis.exists(key)
    logger(__method__, "No categories to remove!")
    response = "There aren't any categories. Say `trebekbot let's play` to start a new round."
  elsif rcategory.nil?
    logger(__method__, "No category specified")
    response = "What's that?"
  else
    match = false
    current_categories = JSON.parse($redis.get(key))
    current_categories.each do |category|
      if rcategory == category['title']
        match = true
        current_categories.delete(category)
      end
      if match == false
        response = "I don't see that category on the board."
      end
    end
    if current_categories.empty?
      response = "And that's it for this round of Jeopardy, everyone. \n"
      if ENV["ENABLE_FINAL_JEOPARDY"] == "true"
        $redis.set("begin_final_jeopardy:#{channel_id}", true)
      else
        response += respond_with_leaderboard()
        $redis.flushdb
      end
    else
      $redis.set(key, current_categories.to_json)
    end
  end
  response
end

def remove_val_from_category(key = nil, rcategory = nil, rval = nil, channel_id)
  to_delete = false
  if !$redis.exists(key)
    logger(__method__, "No categories to remove!")
  elsif rcategory.nil?
    logger(__method__, "No category specified")
  elsif rval.nil?
    logger(__method__, "No value specified")
  else
    current_categories = JSON.parse($redis.get(key))
    current_categories.each do |category|
      if rcategory == category['title']
        if category['values'].include?(rval)
          category['values'].delete(rval)
        end
        if category['values'].empty?
          to_delete = true
        end
      end
    end
    $redis.set(key, current_categories.to_json)
    if to_delete == true
      remove_category(key, rcategory, channel_id)
    end
  end
end

# Processes an answer submitted by a user in response to a Jeopardy round:
# If there's no round, returns a funny SNL Trebek quote.
# Otherwise, responds appropriately if:
# The user already tried to answer;
# The time to answer the round is up;
# The answer is correct and in the form of a question;
# The answer is correct and not in the form of a question;
# The answer is incorrect.
# Update the score and marks the round as answer, depending on the case.
#
def process_answer(params)
  channel_id = params[:channel_id]
  return process_final(params) if $redis.exists("final_category:#{channel_id}")
  user_id = params[:user_id]
  user_nick = params["user_name"]
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  reply = ""
  if current_question.nil?
    reply = trebek_me if !$redis.exists("shush:answer:#{channel_id}")
  else
    current_question = JSON.parse(current_question)
    current_answer = current_question["answer"]
    user_answer = params[:text]
    answered_key = "user_answer:#{channel_id}:#{current_question["id"]}:#{user_id}"
    if $redis.exists(answered_key)
      reply = "You had your chance, #{user_nick}. Let someone else answer."
    elsif params["timestamp"].to_f > current_question["expiration"]
      if is_correct_answer?(current_answer, user_answer)
        reply = "That is correct, #{user_nick}, but time's up! Remember, you only have #{ENV["SECONDS_TO_ANSWER"]} seconds to answer."
      else
        reply = "Time's up, #{user_nick}! Remember, you have #{ENV["SECONDS_TO_ANSWER"]} seconds to answer. The correct answer is `#{current_question["answer"]}`."
      end
      mark_question_as_answered(channel_id)
    elsif is_question_format?(user_answer) && is_correct_answer?(current_answer, user_answer)
      score = update_score(user_id, current_question["value"])
      reply = "That is correct, #{user_nick}. Your total score is #{currency_format(score)}."
      check_final_jeopardy_valid(channel_id)
      mark_question_as_answered(channel_id)
    elsif is_correct_answer?(current_answer, user_answer)
      score = update_score(user_id, (current_question["value"] * -1))
      reply = "That is correct, #{user_nick}, but responses have to be in the form of a question. Your total score is #{currency_format(score)}."
      $redis.setex(answered_key, ENV["SECONDS_TO_ANSWER"], "true")
      check_final_jeopardy_valid(channel_id)
    else
      score = update_score(user_id, (current_question["value"] * -1))
      reply = "@#{user_nick}:  " + trebek_wrong + "  " + trebek_wrong_score + " #{currency_format(score)}."
      $redis.setex(answered_key, ENV["SECONDS_TO_ANSWER"], "true")
    end
  end
  reply
end

def process_final(params)
  channel_id = params[:channel_id]
  user_id = params[:user_id]
  user_nick = params[:user_name]
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  return "You are not a finalist, #{user_nick}." if !$redis.exists("finalist:#{user_id}")

  current_question = JSON.parse(current_question)
  current_question['value'] = $redis.get("finalist_wager:#{user_id}").to_i
  current_answer = current_question['answer']
  user_answer = params[:text]
  answered_key = "finalist_answer:#{user_id}"
  if $redis.exists(answered_key)
    reply = "You had your chance, #{user_nick}. Let someone else answer."
  elsif params["timestamp"].to_f > current_question["expiration"]
    $redis.set(answered_key, user_answer)
    reply = "Time's up, #{user_nick}! Remember, you have #{ENV["SECONDS_TO_ANSWER"]} seconds to answer. \n"
    $redis.set("finalist_final_score:#{user_id}", current_question['value'].to_i * -1)
    reply += finish_final_jeopardy(channel_id, current_question)
  elsif is_question_format?(user_answer) && is_correct_answer?(current_answer, user_answer)
    $redis.set(answered_key, user_answer)
    $redis.set("finalist_final_score:#{user_id}", current_question['value'])
    #score = update_score(user_id, current_question["value"])
    reply = finish_final_jeopardy(channel_id, current_question) if has_everyone_answered_final() == true
  else
    $redis.set(answered_key, user_answer)
    $redis.set("finalist_final_score:#{user_id}", current_question['value'].to_i * -1)
    #score = update_score(user_id, (current_question["value"] * -1))
    reply = finish_final_jeopardy(channel_id, current_question) if has_everyone_answered_final() == true
  end
  reply
end

def has_everyone_answered_final
  b = true

  finalists = parse_score_leaders()
  finalists.each do |finalist|
    if !$redis.exists("finalist_answer:#{finalist[:user_id]}")
      b = false
    end
  end
  b
end

def finish_final_jeopardy(channel_id, current_question)
  response = "The answer for tonight's Final Jeopardy! question is \n"
  response += "`#{current_question['answer']}`. \n"

  finalists = parse_score_leaders()
  finalists.each do |finalist|
    if $redis.exists("finalist_final_score:#{finalist[:user_id]}")
      final_score = $redis.get("finalist_final_score:#{finalist[:user_id]}").to_i
      score = update_score(finalist[:user_id], final_score)
    elsif $redis.exists("finalist_wager:#{finalist[:user_id]}")
      final_score = $redis.get("finalist_wager:#{finalist[:user_id]}").to_i * -1
      score = update_score(finalist[:user_id], final_score)
    else
      score = update_score(finalist[:user_id], finalist[:score].to_i * -1)
    end
  end
  winners = []
  parse_score_leaders.each_with_index do |winner, i|
    user_id = winner[:user_id]
    name = get_slack_name(winner[:user_id])
    score = currency_format(get_user_score(user_id))
    winners << "#{i + 1}. #{name}: #{score}"
  end
  if winners.size > 0
    response += "And now, announcing the winners of tonight's game: \n\n#{winners.join("\n")}"
  else
    response += "Unfortunately, we don't always come out with a winner in Jeopardy!. This is one of those times."
  end
  clear_leaderboard
  response
end

# Formats a number as currency.
# For example -10000 becomes -$10,000
#
def currency_format(number, currency = "$")
  prefix = number >= 0 ? currency : "-#{currency}"
  moneys = number.abs.to_s
  while moneys.match(/(\d+)(\d\d\d)/)
    moneys.to_s.gsub!(/(\d+)(\d\d\d)/, "\\1,\\2")
  end
  "#{prefix}#{moneys}"
end

# Checks if the respose is in the form of a question:
# Removes punctuation and check if it begins with what/where/who
# (I don't care if there's no question mark)
#
def is_question_format?(answer)
  answer.gsub(/[^\w\s]/i, "").match(/^(what|whats|where|wheres|who|whos) /i)
end

# Checks if the user answer matches the correct answer.
# Does processing on both to make matching easier:
# Replaces "&" with "and";
# Removes punctuation;
# Removes question elements ("what is a")
# Strips leading/trailing whitespace and downcases.
# Finally, if the match is not exact, uses White similarity algorithm for "fuzzy" matching,
# to account for typos, etc.
#
def is_correct_answer?(correct, answer)
  correct = correct.gsub(/^(the|a|an) /i, "")
            .gsub(/^(the|a|an) /i, "")
            .gsub("one", "1")
            .gsub("two", "2")
            .gsub("three", "3")
            .gsub("four", "4")
            .gsub("five", "5")
            .gsub("six", "6")
            .gsub("seven", "7")
            .gsub("eight", "8")
            .gsub("nine", "9")
            .gsub("ten", "10")
            .strip
            .downcase

  correct_no_parenthetical = correct.gsub(/\(.*\)/, "").gsub(/[^\w\s]/i, "").strip
  correct_sanitized = correct.gsub(/[^\w\s]/i, "")

  answer = answer
           .gsub(/\s+(&nbsp;|&)\s+/i, " and ")
           .gsub(/[^\w\s]/i, "")
           .gsub(/^(what|whats|where|wheres|who|whos|when|whens) /i, "")
           .gsub(/^(is|are|was|were) /, "")
           .gsub(/^(the|a|an) /i, "")
           .gsub(/\?+$/, "")
           .gsub("one", "1")
           .gsub("two", "2")
           .gsub("three", "3")
           .gsub("four", "4")
           .gsub("five", "5")
           .gsub("six", "6")
           .gsub("seven", "7")
           .gsub("eight", "8")
           .gsub("nine", "9")
           .gsub("ten", "10")
           .strip
           .downcase
  [correct_sanitized, correct_no_parenthetical].each do |solution|
    white = Text::WhiteSimilarity.new
    similarity = white.similarity(solution, answer)
    if solution == answer || similarity >= ENV["SIMILARITY_THRESHOLD"].to_f
      return true
    end
  end
  false
end

# Marks question as answered by:
# Deleting the current question from redis,
# and "shushing" the bot for 5 seconds, so if two users
# answer at the same time, the second one won't trigger
# a response from the bot.
#
def mark_question_as_answered(channel_id)
  $redis.pipelined do
    $redis.del("current_question:#{channel_id}")
    $redis.del("shush:question:#{channel_id}")
    $redis.setex("shush:answer:#{channel_id}", 5, "true")
  end
end


# Returns the given user's score.
#
def respond_with_user_score(user_id, user_name)
  user_score = get_user_score(user_id)
  "#{user_name}, your score is #{currency_format(user_score)}."
end

# Gets the given user's score from redis
#
def get_user_score(user_id)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, 0)
    user_score = 0
  end
  user_score.to_i
end

# Updates the given user's score in redis.
# If the user doesn't have a score, initializes it at zero.
#
def update_score(user_id, score = 0)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  last_user_answered = user_id
  if user_score.nil?
    $redis.set(key, score)
    score
  else
    new_score = user_score.to_i + score
    $redis.set(key, new_score)
    new_score
  end
end

def clear_leaderboard
  $redis.flushdb
  reply = "Thank you for being with us. Goodnight everybody."
  reply
end

# Gets the given user's name(s) from redis.
# If it's not in redis, makes an API request to Slack to get it,
# and caches it in redis for a month.
#
# Options:
# use_real_name => returns the users full name instead of just the first name
#
def get_slack_name(user_id, options = {})
  options = { :use_real_name => false }.merge(options)
  key = "slack_user_names:2:#{user_id}"
  names = $redis.get(key)
  if names.nil?
    names = get_slack_names_hash(user_id)
    $redis.setex(key, 60*60*24*30, names.to_json)
  else
    names = JSON.parse(names)
  end
  if options[:use_real_name]
    name = names["real_name"].nil? ? names["name"] : names["real_name"]
  else
    name = names["first_name"].nil? ? names["name"] : names["first_name"]
  end
  name
end

# Makes an API request to Slack to get a user's set of names.
# (Slack's outgoing webhooks only send the user ID, so we need this to
# make the bot reply using the user's actual name.)
#
def get_slack_names_hash(user_id)
  uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response["ok"]
    user = response["members"].find { |u| u["id"] == user_id }
    names = { :id => user_id, :name => user["name"]}
    unless user["profile"].nil?
      names["real_name"] = user["real_name"] unless user["real_name"].nil? || user["real_name"] == ""
      names["first_name"] = user["profile"]["first_name"] unless user["profile"]["first_name"].nil? || user["profile"]["first_name"] == ""
      names["last_name"] = user["profile"]["last_name"] unless user["profile"]["last_name"].nil? || user["profile"]["last_name"] == ""
    end
  else
    names = { :id => user_id, :name => "Sean Connery" }
  end
  names
end

# When the round's time expires, mark the question as answered
def round_time_expired(channel_id)
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  if !current_question.nil?
    current_question = JSON.parse(current_question)
    current_answer = current_question["answer"]
    mark_question_as_answered(channel_id)
    reponse = "The correct answer is `#{current_answer}`."
  end
  status 200
  body json_response_for_slack(response)
end

# Speaks the top scores across Slack.
# The response is cached for 5 minutes.
#
def respond_with_leaderboard(key = "leaderboard:1", order = "desc", response = "top")
  response = $redis.get(key)
  if response.nil?
    leaders = []
    get_score_leaders({:order => order}).each_with_index do |leader, i|
      user_id = leader[:user_id]
      name = get_slack_name(leader[:user_id])
      score = currency_format(get_user_score(user_id))
      leaders << "#{i + 1}. #{name}: #{score}"
    end
    if leaders.size > 0
      response = "Let's take a look at the #{response} scores:\n\n#{leaders.join("\n")}"
    else
      response = "There are no scores yet!"
    end
    $redis.setex(key, 60*5, response)
  end
  response
end

# Gets N scores from redis, with optional sorting.
#
def get_score_leaders(options = {})
  options = { :limit => 10, :order => "desc" }.merge(options)
  leaders = []
  $redis.scan_each(:match => "user_score:*"){ |key| user_id = key.gsub("user_score:", ""); leaders << { :user_id => user_id, :score => get_user_score(user_id)} }
  if leaders.size > 1
    if options[:order] == "desc"
      leaders = leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.slice(0, options[:limit])
    else
      leaders = leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| a[:score] <=> b[:score] }.slice(0, options[:limit])
    end
  else
    leaders
  end
end

# Parse score leaders with only positive scores
def parse_score_leaders()
  users = []
  $redis.scan_each(:match => "user_score:*"){ |key| user_id = key.gsub("user_score:", ""); users << { :user_id => user_id, :score => get_user_score(user_id), :user_name => get_slack_name(user_id) } }
  finalists = []
  if users.size > 0
    users.each do |user|
      if user[:score] >= 1
        finalists.push(user)
      end
    end
    finalists = finalists.uniq{ |f| f[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.slice(0, 100)
  end
  finalists
end

# Funny quotes from SNL's Celebrity Jeopardy, to speak
# when someone invokes trebekbot and there's no active round.
#
def trebek_me
  [ "Welcome back to Slack Jeopardy. Before we begin this Jeopardy round, I'd like to ask our contestants once again to please refrain from using ethnic slurs.",
    "Okay, Turd Ferguson.",
    "I hate my job.",
    "Let's just get this over with.",
    "Do you have an answer?",
    "I don't believe this. Where did you get that magic marker? We frisked you on the way in here.",
    "What a ride it has been, but boy, oh boy, these Slack users did not know the right answers to any of the questions.",
    "Back off. I don't have to take that from you.",
    "That is _awful_.",
    "Okay, for the sake of tradition, let's take a look at the answers.",
    "Beautiful. Just beautiful.",
    "Good for you. Well, as always, three perfectly good charities have been deprived of money, here on Slack Jeopardy. I'm #{ENV["BOT_USERNAME"]}, and all of you should be ashamed of yourselves! Good night!",
    "And welcome back to Slack Jeopardy. Because of what just happened before during the commercial, I'd like to apologize to all blind people and children.",
    "Thank you, thank you. Moving on.",
    "I really thought that was going to work.",
    "For the last time, that is not a category.",
    "Unbelievable.",
    "Uh, I see. Get back to your podium.",
    "You look pretty sure of yourself. Think you've got the right answer?",
    "Welcome back to Slack Jeopardy. We've got a real barnburner on our hands here.",
    "And welcome back to Slack Jeopardy. I'd like to once again remind our contestants that there are proper bathroom facilities located in the studio.",
    "Welcome back to Slack Jeopardy. Once again, I'm going to recommend that our viewers watch something else.",
    "Don't tell me what you believe in. I'll observe how you behave and I will make my own determination.",
    "It's very important in life to know when to shut up. You should not be afraid of silence."
  ].sample
end

def trebek_wrong_score
  [  "Your score is now",
  	 "That brings you down to",
  	 "How much does that leave you with now?  Oh yes,",
     "How much did you wager?  Ouch.  Well at least you have"
  ].sample
end
def trebek_wrong
	[  "You're fast on the button, but your brain's not catching up!",
     "Nope.  It will be goodbye for you today.",
     "One of the main differences between regular shows and kids week is emotion.  As talented as you are, you havn't had very much experience with not winning.",
     "Ah, if only you had been able to accumulate more money.",
     "You were having difficulties with that signaling device.  I saw.  You won't be around for Final Jeopardy!",
     "It's a shame you weren't faster on the signaling button in earlier rounds.",
     "It's been happening a lot lately.  Two of the players get off to a good start, and you start off badly.",
     "Sorry, Nope.  That's wrong.",
     "You made a common error there.",
     "Let me see if I can make you feel better. It's incorrect.",
     "You've been up and down.  Mostly down.",
     "Maybe the categories didn't agree with you last round.  Perhaps you will like them better in this round.",
     "You'll will try to get yourself out of the whole...when we come back. ",
     "That is incorrect.  And I think you suspected that was wrong.",
     "Ooh, drawing a blank.  That'll cost you.",
     "What we've discovered here on Jeopardy! about you: You don't know recent American history.  And by recent history I mean the past 50 years.",
     "Yeah.  Incorrect.  You should have stuck with your original thought.",
     "You know what they have to do in this Double Jeopardy! round.  First you have to get yourself out of the hole.",
     "We have to penalize you and once again you are in a negative situation.",
     "The way you said that is exactly the way a contestant on Wheel of Fortune would say it.",
     "You have serious education problems.",
     "Your mom cries when you succeed.  How is she dealing with a failure?",
     "Nope.  Not good enough.  Not gonna help you.",
     "Sorry, that ain't gonna do it.",
     "You weren't able to come up with a correct response.",
     "Two words of advice: get serious.",
     "I feared some of you might put that down.  That is incorrect.",
     "You've been burying a very deep hole.  Let's see if you can change that.",
     "Well, THAT narrows it down.",
     "It's very important in life to know when to shut up. You should not be afraid of silence.",
     "I think what makes Jeopardy! special is that, among all the quiz and game shows out there, ours tends to encourage learning.",
     "Hahahahaha... No.",
     "They teach you that in school in Utah, huh?"
   ].sample
end

def value_set
  [  "200",
     "400",
     "600",
     "800",
     "1000"
  ]
end

# Shows the help text.
# If you add a new command, make sure to add some help text for it here.
#
def respond_with_help
  reply = <<help
Type `#{ENV["BOT_USERNAME"]} jeopardy me` to start a new round of Slack Jeopardy. I will pick the category and price. Anyone in the channel can respond.
Type `#{ENV["BOT_USERNAME"]} let's play` or `#{ENV["BOT_USERNAME"]} show the categories` to see a list of the remaining categories or create a new set of categories.
Type `#{ENV["BOT_USERNAME"]} [what|where|who|when] [is|are] [answer]?` to respond to the active round. You have #{ENV["SECONDS_TO_ANSWER"]} seconds to answer. Remember, responses must be in the form of a question, e.g. `#{ENV["BOT_USERNAME"]} what is dirt?`.
Type `#{ENV["BOT_USERNAME"]} I'll take [category] for [value]` start a new round with one of the existing categories.
Type `#{ENV["BOT_USERNAME"]} what is my score` to see your current score.
Type `#{ENV["BOT_USERNAME"]} show the leaderboard` to see the top scores.
Type `#{ENV["BOT_USERNAME"]} show the loserboard` to see the bottom scores.
help
  reply
end

def json_response_for_slack(reply)
  response = { text: reply, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  response.to_json
end
