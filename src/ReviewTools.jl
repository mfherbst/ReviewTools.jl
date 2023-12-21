module ReviewTools
import HTTP
import JSON
using DataFrames
using Dates
using Preferences
using Printf

export set_pretalx_token!, PretalxEvent, submissions, reviews
export update_reviews!, dump_missing_reviews


"""
Set the pretalx token to use for fetching reviews
"""
function set_pretalx_token!(pretalx_token::AbstractString)
    @set_preferences!("pretalx_token" => pretalx_token)
end

struct PretalxEvent
    name::String
end
PretalxEvent() = PretalxEvent("juliacon2023")

reviews_url(event::PretalxEvent) = "https://pretalx.com/api/events/$(event.name)/reviews/"
submission_url(event::PretalxEvent) = "https://pretalx.com/api/events/$(event.name)/submissions/"
function submission_review_url(event::PretalxEvent, code)
    "https://pretalx.com/orga/event/$(event.name)/submissions/$code/reviews/"
end

function get_batch(url::AbstractString)
    pretalx_token = @load_preference("pretalx_token", "")
    if isempty(pretalx_token)
        error("Empty pretalx token, call set_pretalx_token!(\"your_token\") " *
              "where `your_token` is your pretalx API token.")
    end

    params = Dict("Authorization"=> "Token $pretalx_token", "Accept" => "application/json")
    r = HTTP.request("GET", url, params)
    if r.status == 200
        return JSON.parse(IOBuffer(r.body))
    else
        @warn "Failed with" r.status r.body url
        return nothing
    end
end

"""
Get all submissions as a parsed DataFrame
"""
function submissions(event::PretalxEvent)
    data = DataFrame()
    S = get_batch(submission_url(event))
    while true
        url = S["next"]
        for submission in S["results"]
            code  = submission["code"]
            rurl  = submission_review_url(event, code)
            title = submission["title"]
            state = submission["state"]
            pending_state = something(get(submission, "pending_state", state), state)

            # Only include certain kind of proposals (exclude withdrawn)
            valid_states = ("submitted", "accepted", "rejected", "confirmed")
            if !(state in valid_states)
                continue
            end

            track = "JuliaCon"
            trackdict = submission["track"]
            if !isnothing(trackdict)
                track = get(trackdict, "en", track)
            end

            type = "Talk"
            typedict = submission["submission_type"]
            if !isnothing(typedict)
                type = get(typedict, "en", type)
            end

            push!(data, (; code, rurl, title, track, type, state, pending_state))
        end
        if url === nothing
            break
        else
            @info "Visiting $url next"
            S = get_batch(url)
        end
    end

    # Sort the dataframe by title
    sort!(data, [:title])
end

"""
Get all reviews as a parsed DataFrame:
Caveat is you won't get reviews on submissions of the person who's API key you are using.
"""
function reviews(event::PretalxEvent)
    data = DataFrame()
    S = get_batch(reviews_url(event))
    while true
        url = S["next"]
        for review in S["results"]
            if !isnothing(review["score"])
                score = parse(Float64, review["score"])
                text  = review["text"]
                submission = review["submission"]
                reviewer = review["user"]
                push!(data, (; score, text, submission, reviewer))
            end
        end
        if url === nothing
            break
        else
            S = get_batch(url)
        end
    end
    data
end


"""
Update review status on the passed submissions.
"""
function update_reviews!(event::PretalxEvent, submissions)
    submissions.n_reviews   = zeros(Int,   size(submissions, 1))
    submissions.review_text = ones(String, size(submissions, 1))
    for review in eachrow(reviews(event))
        isub = findfirst(submissions.code .== review.submission)
        if !isnothing(isub)
            submissions.n_reviews[isub]   += 1
            submissions.review_text[isub] *= (review.text * "\n")
        end
    end
    submissions
end

function dump_missing_reviews(htmlfile, submissions; n_desired=3, track="JuliaCon")
    # The talk types we don't want reviewed
    exclude_reviewing = ("Break", "Breakfast", "Ceremony", "Gold sponsor talk",
                         "Hackathon", "Keynote", "Lunch Break", "Social hour")
    submissions = filter(submissions) do r
        r.track == track && !(r.type in exclude_reviewing)
    end

    percent(f) = @sprintf "%3.1f%%" 100f

    n_allsubs = size(submissions, 1)
    n_total = n_desired * n_allsubs
    submissions = filter(r -> r.n_reviews < n_desired && r.track == track, submissions)
    n_prop_missing = size(submissions, 1)

    counts = Dict{Int, Int}()
    n_reviews_missing = 0
    for nbin in 0:(n_desired-1)
        cnt = count(s -> s.n_reviews == nbin, eachrow(submissions))
        n_reviews_missing += cnt * (n_desired - nbin)
        counts[nbin] = cnt
    end

    sort!(submissions, [:n_reviews])
    open(htmlfile, "w") do fp
        println(fp, "<html><body>")
        println(fp, "<table><tr><th>Submission</th><th>Code</th><th>n_reviews</th></tr>")
        for s in eachrow(submissions)
            println(fp, "<tr>")
            println(fp, "    <td><a href=\"$(s.rurl)\">$(s.title)</a></td>")
            println(fp, "    <td>$(s.code)</td><td>$(s.n_reviews)</td>")
            println(fp, "</tr>")
        end
        println(fp, "</table>")

        println(fp, "<p>")
        println(fp, "Proposals done: $(n_allsubs - n_prop_missing)  ",
                "($(percent(1 - n_prop_missing / n_allsubs)))<br />")
        println(fp, "Reviews done: $(n_total - n_reviews_missing)  ",
                "($(percent(1 - n_reviews_missing / n_total)))")
        println(fp, "</p>")

        lastupdate = withenv("LANG" => "C") do
            read(`date --utc`, String)
        end
        println(fp, "<p>Last update: $lastupdate</p></body></html>")
    end

    println("Proposals missing reviews: ", n_prop_missing, "/", n_allsubs, " ",
            percent(n_prop_missing / n_allsubs))
    println("Number of reviews missing: ", n_reviews_missing, "/", n_desired * n_allsubs, " ",
            percent(n_reviews_missing / n_total))

    for nbin in 0:(n_desired-1)
        counts[nbin] == 0 && continue
        println("    with $nbin reviews: ", counts[nbin])
    end

    submissions = select!(submissions, Not(:n_reviews))
end

"""
Keep polling and regenerating the missing reviews file every `waittime` seconds.
"""
function loop_dump_missing_reviews(htmlfile, event::PretalxEvent; waittime=600)
    subs = submissions(event)
    while true
        println(Dates.now())
        dump_missing_reviews(htmlfile, update_reviews!(event, sub))
        sleep(waittime)
        println()
    end
end

function main()
    event = PretalxEvent()
    htmlfile = "missing_reviews.html"
    @info "Selecting event $(event.name) and dumping to $(htmlfile)"
    loop_dump_missing_reviews(htmlfile, event)
end
end
