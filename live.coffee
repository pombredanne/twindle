queue = require './lib/queue'
config = require './lib/config'
{createApp} = require './lib/web'
{Storage} = require './lib/storage'

class VoteManager

  constructor: () ->
    self = @
    self.events = {}
    config.getTable (data) ->
      event_name = null
      for row in data
        if row.type == 'event'
          event_name = row.filter
          self.events[event_name] =
            name: row.filter
            label: row.label
            tags: []
        else if row.type == 'track' and event_name isnt null
          s = [[new RegExp("##{row.filter}\\+", 'mi'), 1],
               [new RegExp("##{row.filter}-", 'mi'), -1]]
          self.events[event_name].tags.push
            name: row.filter
            label: row.label
            sentiments: s
      console.log self.events
    self.storage = new Storage()

  saveStatus: (status, callback) ->
    self = @
    #console.log "Reading: #{status.text}"
    for event, event_data of self.events
      for tag in event_data.tags
        for [regex, value] in tag.sentiments
          if regex.test status.text
            self.saveVote status, event, tag.name, value
    callback()

  saveVote: (status, event, tag, value) ->
    console.log "Vote: #{event}: #{tag} - #{value}: #{status.text}"
    @storage.client.query 'INSERT INTO "vote" (status_id, event, tag, sentiment, created_at)
      VALUES ($1, $2, $3, $4, NOW())', [status.id, event, tag, value], (err, result) -> 
        if err?
          console.log err

  getVotes: (event, sample, interval, callback) ->
    self = @
    console.log [sample, interval, event]
    @storage.client.query "SELECT v.tag AS tag, v.sentiment AS sentiment,
        TIMESTAMP WITH TIME ZONE 'epoch' + INTERVAL '1 second' *
        round(extract('epoch' from v.created_at) / $1) * $1 AS sample,
        COUNT(v.id) AS count
        FROM vote v
        WHERE v.created_at > NOW() - (INTERVAL '1 second' * $2)
        AND v.event = $3
        GROUP BY v.tag, v.sentiment, round(extract('epoch' from created_at) / $1)
        ORDER BY sample DESC
        ", [interval, sample, event], (err, res) ->
      if err?
        return callback null, err
      callback res.rows, null


votemanager = new VoteManager()
queue.consume "live", votemanager

app = createApp
  generateStatistics: (cb) -> cb {}
  getLatest: (cb) -> cb {}

app.get '/votes', (req, res) ->
  console.log req.query
  if not req.query.event or not votemanager.events[req.query.event]?
    return res.jsonp 400,
      status: 'error'
      message: "No such event: #{req.query.event}"
  sample = Math.min 84600, (parseInt(req.query.sample, 10) || 7200)
  interval = Math.max 10, (parseInt(req.query.interval, 10) || 10)
  console.log sample, interval
  votemanager.getVotes req.query.event, sample, interval, (rows, err) ->
    if err?
      res.jsonp 500,
        status: 'error',
        message: '' + err
    res.jsonp 200,
      status: 'ok'
      event: votemanager.events[req.query.event]
      data: rows

app.listen 4000 #config.port

