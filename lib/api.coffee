async = require 'async'
util = require 'util'
logger = require 'winston'
settings = require '../settings'
eventModule = require './event'
Subscriber = require('./subscriber').Subscriber
fs = require('fs');

Message = settings.Message

filterFields = (params) ->
	fields = {}
	fields[key] = val for own key, val of params when key in ['proto', 'token', 'lang', 'badge', 'version', 'category', 'contentAvailable']
	return fields

# appId, appDebug, os, appHash, appUsername
exports.setupRestApi = (redis, app, createSubscriber, getEventFromId, authorize, testSubscriber, eventPublisher, checkStatus) ->

	authorize ?= (realm) ->

	app.post '/apps/register', authorize('anonymous'), (req, res) ->

		#logger.info("======================================")
		#logger.info("============== body = #{JSON.stringify(req.body)}")
		#logger.info("======================================")


		configs = settings.configs


		appId = req.body.appId
		appUserEmail = req.body.appUserEmail || ""
		appUserName = req.body.appUserName || ""
		proto = req.body.proto || ""
		appHash = req.body.appHash
		appDebug = if req.body.appDebug == true || req.body.appDebug == 'S' then true else false
		server_name = "nenhum"
		apn_name_general = "nenhum"
		apn_name_mobilemind = "nenhum"
		app_type = req.body.os || 'ios'
		channels = ""
		channels_default = configs.apps.defaults_channels
		deviceId = req.body.deviceId || ""

		if !appUserEmail || appUserEmail.trim().length == 0
			res.status 500.json error: "user name is required"
			return

		if !appUserName || appUserName.trim().length == 0
			res.status 500.json error: "user name is required"
			return

		server_name_sufix = undefined
		channels_sufix = undefined

		for it in configs.apps.channels
			if it.appid == appId
				server_name_sufix = it.server_name
				channels_sufix = it.channels


		if !server_name_sufix
			res.status 500.json error: "server name not found to appId #{appid}"
			return

		if !channels_sufix
			res.status 500.json error: "channels not found to appId #{appid}"
			return


		if appDebug
			for sufix in channels_sufix
				channels += "#{sufix}-dev,"

			for channel in channels_default
				channels += "#{channel}-dev,"
		else
			for sufix in channels_sufix
				channels += "#{sufix},"

			for channel in channels_default
				channels += "#{channel},"

		if app_type == 'ios'

			proto = "apns"

			if appDebug
				server_name = "apns-#{server_name_sufix}-dev"
			else
				server_name = "apns-#{server_name_sufix}"

		else if app_type == 'android'

			if !proto || proto == ""
				proto = "gcm"

			if appDebug
				server_name = "#{proto}-#{server_name_sufix}-dev"
			else
				server_name = "#{proto}-#{server_name_sufix}"

		data = {
			server_name: server_name,
			subscrible_channels: channels,
			app_id: appId,
			app_hash: appHash,
			app_user_email: appUserEmail,
			app_debug: appDebug,
			app_user_name: appUserName
			deviceId: deviceId
			updatedAt: new Date()
		}

		logger.info("*************** data app config")
		logger.info(JSON.stringify(data))
		logger.info("*************** data app config")

		queryArgs = {}

		if data.deviceId && data.deviceId.trim().length > 0
			queryArgs = { app_debug: appDebug, deviceId: data.deviceId, app_id: appId }
		else
			queryArgs = { app_hash: data.app_hash, app_debug: appDebug, app_id: appId  }

	app.get '/apps/index', authorize('admin'), (req, res) ->
		res.render('index', {})

	app.get '/apps/remove/:subscriber_id', authorize('admin'), (req, res) ->

		subscriber_deleted = false

		logger.info("trying remove subscriber #{req.params.subscriber_id}")
		req.subscriber.get (sub) ->

			if sub
				req.subscriber.delete (deleted) ->

					if not deleted
						logger.error "No subscriber #{req.subscriber.id} remove. Not deleted"
					else
						subscriber_deleted = true

			else
				logger.error "No subscriber #{req.subscriber.id} found to redis remove"

	app.get '/apps/:channel', authorize('publish'), (req, res) ->

		channel = req.params.channel

		if !channel || channel.trim().length == 0
			res.status(500).json error: "channels param is required"
			return

	# subscriber registration

	subscribers = (body, res, end) ->

		logger.verbose "Registering subscriber: #{JSON.stringify(body)}"

		try
			fields = filterFields(body)
			createSubscriber fields, (subscriber, created) ->
				subscriber.get (info) ->
					info.id = subscriber

					logger.info("subscriber #{subscriber.id} register created: #{created}")

					if end
						end(subscriber)
						return

					res.header 'Location', "/subscriber/#{subscriber.id}"
					res.status((if created then 201 else 200)).json {}
		catch error

			logger.error "Creating subscriber failed: #{error.message}"

			if end
				end()
				return

			res.status(400).json error: error.message

	app.post '/subscribers', authorize('register'), (req, res) ->
		subscribers(req.body, res)

	# Get subscriber info
	app.get '/subscriber/:subscriber_id', authorize('register'), (req, res) ->
		req.subscriber.get (fields) ->
			if not fields?
				logger.error "No subscriber #{req.subscriber.id}"
			else
				logger.verbose "Subscriber #{req.subscriber.id} info: " + JSON.stringify(fields)
			res.status((if fields? then 200 else 404)).json fields

	# Edit subscriber info
	app.post '/subscriber/:subscriber_id', authorize('register'), (req, res) ->
		logger.verbose "Setting new properties for #{req.subscriber.id}: " + JSON.stringify(req.body)
		fields = filterFields(req.body)
		req.subscriber.set fields, (edited) ->
			if not edited
				logger.error "No subscriber #{req.subscriber.id}"
			res.sendStatus if edited then 204 else 404

	# Unregister subscriber
	app.delete '/subscriber/:subscriber_id', authorize('register'), (req, res) ->
		req.subscriber.delete (deleted) ->
			if not deleted
				logger.error "No subscriber #{req.subscriber.id}"
			res.sendStatus if deleted then 204 else 404

	app.post '/subscriber/:subscriber_id/test', authorize('register'), (req, res) ->
		testSubscriber(req.subscriber)
		res.sendStatus 201

	# Get subscriber subscriptions
	app.get '/subscriber/:subscriber_id/subscriptions', authorize('register'), (req, res) ->
		req.subscriber.getSubscriptions (subs) ->
			if subs?
				subsAndOptions = {}
				for sub in subs
					subsAndOptions[sub.event.name] = {ignore_message: (sub.options & sub.event.OPTION_IGNORE_MESSAGE) isnt 0}
				logger.verbose "Status of #{req.subscriber.id}: " + JSON.stringify(subsAndOptions)
				res.json subsAndOptions
			else
				logger.error "No subscriber #{req.subscriber.id}"
				res.sendStatus 404

	# Set subscriber subscriptions
	app.post '/subscriber/:subscriber_id/subscriptions', authorize('register'), (req, res) ->
		subsToAdd = req.body
		logger.verbose "Setting subscriptions for #{req.subscriber.id}: " + JSON.stringify(req.body)
		for eventId, optionsDict of req.body
			try
				event = getEventFromId(eventId)
				options = 0
				if optionsDict? and typeof(optionsDict) is 'object' and optionsDict.ignore_message
					options |= event.OPTION_IGNORE_MESSAGE
				subsToAdd[event.name] = event: event, options: options
			catch error
				logger.error "Failed to set subscriptions for #{req.subscriber.id}: #{error.message}"
				res.status(400).json error: error.message
				return

		req.subscriber.getSubscriptions (subs) ->
			if not subs?
				logger.error "No subscriber #{req.subscriber.id}"
				res.sendStatus 404
				return

			tasks = []

			for sub in subs
				if sub.event.name of subsToAdd
					subToAdd = subsToAdd[sub.event.name]
					if subToAdd.options != sub.options
						tasks.push ['set', subToAdd.event, subToAdd.options]
					delete subsToAdd[sub.event.name]
				else
					tasks.push ['del', sub.event, 0]

			for eventName, sub of subsToAdd
				tasks.push ['add', sub.event, sub.options]

			async.every tasks, (task, callback) ->
				[action, event, options] = task
				if action == 'add'
					req.subscriber.addSubscription event, options, (added) ->
						callback(added)
				else if action == 'del'
					req.subscriber.removeSubscription event, (deleted) ->
						callback(deleted)
				else if action == 'set'
					req.subscriber.addSubscription event, options, (added) ->
						callback(!added) # should return false
			, (result) ->
				if not result
					logger.error "Failed to set properties for #{req.subscriber.id}"
				res.sendStatus if result then 204 else 400

	# Get subscriber subscription options
	app.get '/subscriber/:subscriber_id/subscriptions/:event_id', authorize('register'), (req, res) ->
		req.subscriber.getSubscription req.event, (options) ->
			if options?
				res.json {ignore_message: (options & req.event.OPTION_IGNORE_MESSAGE) isnt 0}
			else
				logger.error "No subscriber #{req.subscriber.id}"
				res.sendStatus 404

	# Subscribe a subscriber to an event
	app.post '/subscriber/:subscriber_id/subscriptions/:event_id', authorize('register'), (req, res) ->
		options = 0
		if parseInt req.body.ignore_message
			options |= req.event.OPTION_IGNORE_MESSAGE
		req.subscriber.addSubscription req.event, options, (added) ->
			if added? # added is null if subscriber doesn't exist
				res.sendStatus if added then 201 else 204
			else
				logger.error "No subscriber #{req.subscriber.id}"
				res.sendStatus 404

	# Unsubscribe a subscriber from an event
	app.delete '/subscriber/:subscriber_id/subscriptions/:event_id', authorize('register'), (req, res) ->
		req.subscriber.removeSubscription req.event, (deleted) ->
			if not deleted?
				logger.error "No subscriber #{req.subscriber.id}"
			else if not deleted
				logger.error "Subscriber #{req.subscriber.id} was not subscribed to #{req.event.name}"
			res.sendStatus if deleted then 204 else 404

	# Event stats
	app.get '/event/:event_id', authorize('register'), (req, res) ->
		req.event.info (info) ->
			if not info?
				logger.error "No event #{req.event.name}"
			else
				logger.verbose "Event #{req.event.name} info: " + JSON.stringify info
			res.status((if info? then 200 else 404)).json info

	# Publish an event
	app.post '/event/:event_id', authorize('publish'), (req, res) ->
		res.sendStatus 204
		eventPublisher.publish(req.event, req.body)

	# Delete an event
	app.delete '/event/:event_id', authorize('publish'), (req, res) ->
		req.event.delete (deleted) ->
			if not deleted
				logger.error "No event #{req.event.name}"
			if deleted
				res.sendStatus 204
			else
				res.sendStatus 404
	# Server status
	app.get '/status', authorize('register'), (req, res) ->
		if checkStatus()
			res.sendStatus 204
		else
			res.sendStatus 503
