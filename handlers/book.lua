local Book = {}

function Book.get(api, req)
    local b = api.current_book()
    if not b then
        return { status = 204 }
    end
    return {
        status = 200,
        json = {
            title = b.title,
            author = b.author,
            page = b.page,
            pages = b.pages,
            percent = b.percent,
            time_spent = b.time_spent,
        },
    }
end

function Book.cover(api, req)
    local png = api.cover_png()
    if not png then
        return { status = 204 }
    end
    return { status = 200, body = png, content_type = "image/png" }
end

return Book
