# Description:
#   Messing around with the YouTube API.
#
# Commands:
#   hubot youtube me <query> - Searches YouTube for the query and returns the video embed link.
module.exports = (robot) ->
  robot.respond /(youtube|yt|trailer)( me)? (.*)/i, (msg) ->
    query = if msg.match[1] == 'trailer' then "#{msg.match[3]} trailer" else msg.match[3]
    robot.http("http://gdata.youtube.com/feeds/api/videos")
      .query({
        orderBy: "relevance"
        'max-results': 15
        alt: 'json'
        q: query
      })
      .get() (err, res, body) ->
        videos = JSON.parse(body)
        videos = videos.feed.entry

        unless videos?
          msg.send "No video results for \"#{query}\""
          return

        video  = msg.random videos
        video.link.forEach (link) ->
          if link.rel is "alternate" and link.type is "text/html"
            msg.send link.href

