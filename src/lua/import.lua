-- © 2008 David Given.
-- WordGrinder is licensed under the MIT open source license. See the COPYING
-- file in this distribution for the full text.
--
-- $Id$
-- $URL$

local ITALIC = wg.ITALIC
local UNDERLINE = wg.UNDERLINE
local ParseWord = wg.parseword
local WriteU8 = wg.writeu8
local bitand = wg.bitand
local bitor = wg.bitor
local bitxor = wg.bitxor
local bit = wg.bit
local string_char = string.char
local string_find = string.find
local string_sub = string.sub
local table_concat = table.concat

function ParseStringIntoWords(s)
	local words = {}
	for w in s:gmatch("[^ \t\r\n]+") do
		words[#words + 1] = CreateWord(w)
	end
	if (#words == 0) then
		return {CreateWord()}
	end
	return words
end

-- Import helper functions. These functions build styled words and paragraphs.

function CreateImporter(document)
	local pbuffer
	local wbuffer
	local oldattr
	local attr
	
	return
	{
		reset = function(self)
			pbuffer = {}
			wbuffer = {}
			oldattr = 0
			attr = 0
		end,

		style_on = function(self, a)
			attr = bitor(attr, a)
		end,
	
		style_off = function(self, a)
			attr = bitxor(bitor(attr, a), a)
		end,
	
		text = function(self, t)
			if (oldattr ~= attr) then
				wbuffer[#wbuffer + 1] = string_char(16 + attr)
				oldattr = attr
			end
		
			wbuffer[#wbuffer + 1] = t
		end,
	 
		flushword = function(self, force)
			if (#wbuffer > 0) or force then
				local s = table_concat(wbuffer)
				pbuffer[#pbuffer + 1] = CreateWord(s)
				wbuffer = {}
				oldattr = 0
			end
		end,
	
		flushparagraph = function(self, style)
			style = style or "P"
			
			if (#wbuffer > 0) then
				self:flushword()
			end
			
			if (#pbuffer > 0) then
				local p = CreateParagraph(DocumentSet.styles[style], pbuffer)
				document:appendParagraph(p)
				
				pbuffer = {}
			end
		end
	}
end

-- The importers themselves.

local function loadtextfile(fp)
	local document = CreateDocument()
	for l in fp:lines() do
		l = CanonicaliseString(l)
		l = l:gsub("%c+", "")
		local p = CreateParagraph(DocumentSet.styles["P"], ParseStringIntoWords(l))
		document:appendParagraph(p)
	end
	
	return document
end

local function loadhtmlfile(fp)
	local data = fp:read("*a")

	-- Collapse whitespace; this makes things far easier to parse.

	data = data:gsub("[\t\f]", " ")
	data = data:gsub("\r\n", "\n")

	-- Canonicalise the string, making it valid UTF-8.

	data = CanonicaliseString(data)
	
	-- Collapse complex elements.
	
	data = data:gsub("< ?(%w+) ?[^>]*(/?)>", "<%1%2>")
	
	-- Helper function for reading tokens from the HTML stream.
	
	local pos = 1
	local len = data:len()
	local function tokens()
		if (pos >= len) then
			return nil
		end
		
		local s, e, t
		s, e, t = string_find(data, "^([ \n])", pos)
		if s then pos = e+1 return t end
		
		if string_find(data, "^%c") then
			pos = pos + 1
			return tokens()
		end
		
		s, e, t = string_find(data, "^(<[^>]*>)", pos)
		if s then pos = e+1 return t:lower() end
		
		s, e, t = string_find(data, "^(&[^;]-;)", pos)
		if s then pos = e+1 return t end
		
		s, e, t = string_find(data, "^([^ <&\n]+)", pos)
		if s then pos = e+1 return t end
		
		t = string_sub(data, pos, pos+1)
		pos = pos + 1
		return t
	end
	
	-- Skip tokens until we hit a <body>.
	
	for t in tokens do
		if (t == "<body>") then
			break
		end
	end

	-- Define the element look-up table.
	
	local document = CreateDocument()
	local importer = CreateImporter(document)
	local style = "P"
	local pre = false
	
	local function flush()
		importer:flushparagraph(style)
		style = "P"
	end
	
	local function flushword()
		importer:flushword(pre)
	end
	
	local function flushpre()
		flush()
		if pre then
			style = "PRE"
		end
	end

	local elements =
	{
		[" "] = flushword,
		["<p>"] = flush,
		["<br>"] = flushpre,
		["<br/>"] = flushpre,
		["</h1>"] = flush,
		["</h2>"] = flush,
		["</h3>"] = flush,
		["</h4>"] = flush,
		["<h1>"] = function() flush() style = "H1" end,
		["<h2>"] = function() flush() style = "H2" end,
		["<h3>"] = function() flush() style = "H3" end,
		["<h4>"] = function() flush() style = "H4" end,
		["<li>"] = function() flush() style = "LB" end,
		["<i>"] = function() importer:style_on(ITALIC) end,
		["</i>"] = function() importer:style_off(ITALIC) end,
		["<em>"] = function() importer:style_on(ITALIC) end,
		["</em>"] = function() importer:style_off(ITALIC) end,
		["<u>"] = function() importer:style_on(UNDERLINE) end,
		["</u>"] = function() importer:style_off(UNDERLINE) end,
		["<pre>"] = function() flush() style = "PRE" pre = true end,
		["</pre>"] = function() flush() pre = false end,
		["\n"] = function() if pre then flush() style = "PRE" else flushword() end end
	}
	
	-- Actually do the parsing.
	
	importer:reset()
	for t in tokens do
		local e = elements[t]
		if e then
			e()
		elseif string_find(t, "^<") then
			-- do nothing
		elseif string_find(t, "^&") then
			e = DecodeHTMLEntity(t)
			if e then
				importer:text(e)
			end
		else
			importer:text(t)
		end
	end
	flush()

	return document
end

-- Does the standard selector-box-and-progress UI for each importer.

local function generic_importer(filename, title, callback)
	if not filename then
		filename = FileBrowser(title, "Import from:", false)
		if not filename then
			return false
		end
	end
	
	ImmediateMessage("Importing...")	

	-- Actually import the file.
	
	local fp = io.open(filename)
	if not fp then
		return nil
	end
	
	local document = callback(fp)
	if not document then
		ModalMessage(nil, "The import failed, probably because the file could not be found.")
		QueueRedraw()
		return false
	end
		
	fp:close()
	
	-- All the importers produce a blank line at the beginning of the
	-- document (the default content made by CreateDocument()). Remove it.
	
	if (#document > 1) then
		document:deleteParagraphAt(1)
	end
	
	-- Add the document to the document set.
	
	local docname = Leafname(filename)

	if DocumentSet.documents[docname] then
		local id = 1
		while true do
			local f = docname.."-"..id
			if not DocumentSet.documents[f] then
				docname = f
				break
			end
		end
	end
	
	DocumentSet:addDocument(document, docname)
	DocumentSet:setCurrent(docname)

	QueueRedraw()
	return true
end

-- Front ends.

function Cmd.ImportTextFile(filename)
	return generic_importer(filename, "Import Text File", loadtextfile)
end

function Cmd.ImportHTMLFile(filename)
	return generic_importer(filename, "Import HTML File", loadhtmlfile)
end
