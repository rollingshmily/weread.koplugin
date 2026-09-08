return function(root, extra)
    extra = extra or {}
    extra.can_eink_download = extra.can_eink_download or function() return true end
    extra.eink_credentials = extra.eink_credentials or function() return "vid", "token" end
    extra.eink_download_to_file = extra.eink_download_to_file or function(_self, _book_id, _param, path)
        local src = root .. "/einksrc"
        os.execute("mkdir -p " .. string.format("%q", src))
        for index = 1, 8 do
            local handle = io.open(src .. "/" .. tostring(index) .. ".txt", "wb")
            handle:write("chapter " .. tostring(index))
            handle:close()
        end
        os.execute(string.format("tar -cf %q -C %q .", path, src))
        return "", 200, {}
    end
    return extra
end
