apns = require 'apn'

class PushServiceAPNS
    tokenFormat: /^[0-9a-f]{64}$/i
    validateToken: (token) ->
        if PushServiceAPNS::tokenFormat.test(token)
            return token.toLowerCase()

    constructor: (conf, @logger, tokenResolver) ->
        conf.errorCallback = (errCode, note) =>
            @logger?.error("APNS Error #{errCode}: #{note}")
        @driver = new apns.Provider(conf)

        @payloadFilter = conf.payloadFilter
        
        @conf = conf

    push: (subscriber, subOptions, payload) ->
        subscriber.get (info) =>
            note = new apns.Notification()
            device = info.token
            if subOptions?.ignore_message isnt true and alert = payload.localizedMessage(info.lang)
                note.alert = alert

            badge = parseInt(payload.badge || info.badge)
            if payload.incrementBadge
                badge += 1
            
            category = payload.category
            contentAvailable = payload.contentAvailable

            if not contentAvailable? and @conf.contentAvailable?
              contentAvailable = @conf.contentAvailable

            if not category? and @conf.category?
              category = @conf.category

            note.badge = badge if not isNaN(badge)
            note.sound = payload.sound
            note.category = category
            note.contentAvailable = contentAvailable
            if @payloadFilter?
                for key, val of payload.data
                    note.payload[key] = val if key in @payloadFilter
            else
                note.payload = payload.data
            @driver.send note, device
            # On iOS we have to maintain the badge counter on the server
            if payload.incrementBadge
                subscriber.incr 'badge'

exports.PushServiceAPNS = PushServiceAPNS
