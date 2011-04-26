-- Main client program for monitoring the space probe

-- Requirents:
-- lua 5.1 or newer

require "config"
require "utils"
require "probe"
require "knob"
require "bbl-twitter"

twitter_client = client(config.oauth_consumer_key, config.oauth_consumer_secret, 
								config.oauth_access_key, config.oauth_access_secret)

function startup()
	-- make sure we can see the probe before we start up at all
	check_probe_connection()

	-- Determine initial space state (doesn't send any notices during startup)
	probe.leds_off()
	local pos = probe.get_position()
	local space_open = pos and ( pos > config.knob_deadband )
	log("Starting with space " .. "open" and space_open or "closed")

	if space_open then
		probe.green_glow()
	end

	-- Kick off with our initial state
	if space_open then 
		est_closing_time = os.time() + translate(pos, config.knob_table)*60*60
		log("Estimated closing " .. os.date(nil, est_closing_time))
		return space_is_open() 
	else 
		return space_is_closed() 
	end
end
	  
warnings = 0

space_opened_at=os.time()

-- State
function space_is_open()
	check_probe_connection()
	sleep(1)

	local hours_left = (est_closing_time - os.time())/60/60
	probe.set_dial(round(translate(hours_left, config.dial_table)))

	local hours = knob.get_movement()
	if hours == 0 then
		-- Space just closed
		space_closing_now()
		return space_is_closed()
	elseif hours ~= nil then
		-- Dial moved to a different non-zero number
		space_closing_in(hours, true)
	end
	
	if os.time() > est_closing_time and warnings < 4 then -- est. closing is now
		log("Due to close now!!!")
		probe.buzz(15)
		probe.slow_blue_blink(100)
		warnings = 4
	elseif os.time() + 1*60 > est_closing_time and warnings < 3 then -- 1 minute to est. closing
		log("1 minute to estimated closing...")
		probe.buzz(10)
		probe.slow_blue_blink(250)
		warnings = 3
	elseif os.time() + 5*60 > est_closing_time and warnings < 2 then -- 5 minutes to est. closing
		log("5 minutes to estimated closing...")
		probe.buzz(5)
		probe.slow_blue_blink(500)
		warnings = 2
	elseif os.time() + 30*60 > est_closing_time and warnings < 1 then -- 30 minutes to est. closing
		log("30 minutes to estimated closing...")
		probe.buzz(2)
		probe.slow_blue_blink(1000)
		warnings = 1
	end

	return space_is_open()
end

-- State
function space_is_closed()
	check_probe_connection()
	sleep(1)

	local hours = knob.get_movement()
	if hours ~= nil and hours > 0 then
		-- Space just opened
		space_closing_in(hours, false)
		return space_is_open()
	end
	return space_is_closed()
end


function check_probe_connection()
	if probe.get_offline() then
		log("Probe offline. Waiting for reconnection...")
		while probe.get_offline() do
			sleep(1)
		end
	end
end

-- Space just opened, or opening hours changed
function space_closing_in(hours, was_already_open)
	est_closing_time = os.time() + hours*60*60	
	log("Estimated closing " .. os.date(nil, est_closing_time))

	if not was_already_open then
		space_opened_at = os.time()
	end
	probe.set_dial(round(translate(hours, config.dial_table)))
	local prep = was_already_open and "will remain" or "is now"
	local adverb = was_already_open and "another" or "" 
	local est_closing_rounded = round(est_closing_time * 60*15) /60/15 -- round to 15 minute interval
	local msg = string.format("The MHV space %s open for approximately %s %s (~%s)", 
									  prep, adverb, hours_rounded(hours), os.date("%H:%M",est_closing_rounded))
	update_world(msg)

	probe.green_glow()

	warnings = 0
	return space_is_open()
end

-- Space is closing now
function space_closing_now()
	probe.set_dial(0)

	local duration = os.time() - space_opened_at
	if duration < 180 then
		duration = string.format("%d seconds", duration)
	elseif duration < 60*180 then
		duration = string.format("%d minutes", duration/60)
	elseif duration < 60*60*24 then
		duration = hours_rounded(duration/60/60)
	else
		duration = string.format("%.1f days", duration/60/60/24)
	end
	-- ironically, the duraiton is necessary to stop twitter dropping duplicate tweets!
	update_world("The MHV space is now closed (was open " .. duration .. ")")
	return space_is_closed()
end

function update_world(msg)
	probe.fast_green_blink()
	msg = string.gsub(msg, "  ", " ")
	log(msg)

	-- email
	local email = io.open("/tmp/mhv_email", "w+")
	email:write("Date: " .. os.date() .. "\n")
	email:write("From: " .. config.smtp_from .. "\n")
	email:write("To: " .. config.smtp_to .. "\n")
	email:write("Subject: " .. msg .. "\n")
	email:write("\n\nThis message was sent automatically by the MHV Space Probe.\n\n")
	email:close()
	os.execute("cat /tmp/mhv_email | " .. config.smtp_cmd .. " &")

	-- twitter
	local retries = 0
	while update_status(twitter_client, msg) == "" and retries < config.max_twitter_retries do
		probe.get_offline() -- keep the probe awake
		sleep(5)
		probe.get_offline() -- keep the probe awake
		retries = retries + 1
	end
	if retries == config.max_twitter_retries then
		log("Failed to tweet... :(")
	end
	log("Done communicating message")
	probe.leds_off()
end


-- Return number of hours, rounded to nearest 1/4 hour, as string
function hours_rounded(hours)
	-- precision needed depends on how far away closing time is
	if hours > 6 then 
		hours = round(hours)
	elseif hours > 2 then 
		hours = round(hours * 2) / 2
	else
		hours = round(hours * 4) / 4
	end
	local fraction_name = { "", " 1/4", " 1/2", " 3/4" }
	local whole = math.floor(hours)
	if whole == 0 and hours > 0.125 then whole = "" end
	local suffix = "s"
	if hours <= 1 then suffix = "" end
	return string.format("%s%s hour%s", whole, fraction_name[((hours % 1)*4)+1], suffix)
end


return startup()