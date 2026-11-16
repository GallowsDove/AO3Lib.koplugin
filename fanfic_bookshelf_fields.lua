-- One field list shared by book details, shelf filters and library search.
local _ = require("gettext")
local M = {}
function M.list()
    return {
        {key="ao3_authors", title=_("Author(s)"), label=_("AO3 author")},
        {key="ao3_categories", title=_("Category"), label=_("AO3 category")},
        {key="ao3_ratings", title=_("Rating"), label=_("AO3 rating")},
        {key="ao3_warnings", title=_("Archive warnings"), label=_("AO3 warning")},
        {key="ao3_fandoms", title=_("Fandoms"), label=_("AO3 fandom"), tags=true},
        {key="ao3_relationships", title=_("Relationships"), label=_("AO3 relationship"), tags=true},
        {key="ao3_characters", title=_("Characters"), label=_("AO3 character"), tags=true},
        {key="ao3_completion", title=_("Work status"), label=_("AO3 completion")},
        {key="ao3_tags", title=_("Additional tags"), label=_("AO3 additional tag"), tags=true},
        {key="ao3_unread", title=_("Reading status"), label=_("AO3 unread chapters"), no_search=true},
    }
end
function M.label(key, value)
    local labels = {
        ao3_completion={complete=_("Complete"), in_progress=_("Work in progress"), unknown=_("Unknown")},
        ao3_unread={unread=_("Has unread chapters"), read=_("All downloaded chapters read"), unknown=_("Unknown")},
    }
    return labels[key] and labels[key][value] or value
end
return M
