CHECKPOINT_PREFIX = '#!%!'
CHECKPOINT_SUFFIX = '!%!#'
exports.CHECKPOINT_PATTERN = new RegExp("#{ CHECKPOINT_PREFIX }\\d+#{ CHECKPOINT_SUFFIX }", 'g')

# HTML quote indicators (tag ids)
QUOTE_IDS = ['OLK_SRC_BODY_SECTION']

# Create an instance of Document using the message html and the injected base document
exports.createEmailDocument = (msgBody, dom) ->
  emailDocument = dom.implementation.createDocument('http://www.w3.org/1999/xhtml', 'html', null)

  # Write html of email to `html` element
  [htmlElement] = emailDocument.getElementsByTagName('html');
  htmlElement.innerHTML = msgBody.trim();

  # Get the body element (will be created if not in the supplied html) and assign it to document.body for ease of use
  # if not already done by the dom implementation
  unless emailDocument.body?
    [emailBodyElement] = emailDocument.getElementsByTagName('body')
    emailDocument.body = emailBodyElement

  # Remove 'head' element from document
  [head] = emailDocument.getElementsByTagName('head')
  emailDocument.documentElement.removeChild(head)

  return emailDocument

# Recursively adds checkpoints to html tree.
exports.addCheckpoints = (htmlNode, counter) ->
  # 3 is a text node
  if htmlNode.nodeType == 3
    htmlNode.nodeValue = "#{ htmlNode.nodeValue.trim() }#{ CHECKPOINT_PREFIX }#{ counter }#{ CHECKPOINT_SUFFIX }\n"
    counter++

  # 1 is an element
  if htmlNode.nodeType == 1
    # Pad with spacing to ensure there are text nodes at the begining and end of non-body elements
    htmlNode.innerHTML = "  #{  htmlNode.innerHTML }  " unless htmlNode.tagName == 'body'
    # Ensure that there are text nodes between sibling elements
    ensureTextNodeBetweenChildElements(htmlNode)
    for childNode in htmlNode.childNodes
      counter = exports.addCheckpoints(childNode, counter)

  return counter

exports.deleteQuotationTags = (htmlNode, counter, quotationCheckpoints) ->
  tagInQuotation = true

  # 3 is a text node
  if htmlNode.nodeType == 3
    tagInQuotation = false unless quotationCheckpoints[counter]
    counter++
    return [counter, tagInQuotation]

  # 1 is an element
  if htmlNode.nodeType == 1
    # Collect child nodes that are marked as in the quotation
    quotationChildren = []
    for childNode in htmlNode.childNodes
      [counter, childTagInQuotation] = exports.deleteQuotationTags(childNode, counter, quotationCheckpoints)
      # Keep tracking if all children are in the quotation
      tagInQuotation = tagInQuotation && childTagInQuotation
      if childTagInQuotation
        quotationChildren.push childNode

  # If all of an element's children are part of a quotation, let parent delete whole element
  if tagInQuotation
    return [counter, tagInQuotation]
  else
    # Otherwise, delete specific quotation children
    for childNode in quotationChildren
      htmlNode.removeChild(childNode)
    return [counter, tagInQuotation]

exports.cutGmailQuote = (emailDocument) ->
  nodesArray = emailDocument.getElementsByClassName('gmail_quote')
  return false unless nodesArray.length > 0

  removeNodes(nodesArray)
  return true

exports.cutMicrosoftQuote = (emailDocument) ->
  splitterElement = findMicrosoftSplitter(emailDocument)
  return false unless splitterElement?

  parentElement = splitterElement.parentElement
  afterSplitter = splitterElement.nextElementSibling
  while afterSplitter?
    parentElement.removeChild(afterSplitter)
    afterSplitter = splitterElement.nextElementSibling

  parentElement.removeChild(splitterElement)
  return true

# Remove the last non-nested blockquote element
exports.cutBlockQuote = (emailDocument) ->
  xpathQuery = '(.//blockquote)[not(ancestor::blockquote)][last()]'
  xpathResult = emailDocument.evaluate(xpathQuery, emailDocument, null, 9, null)

  blockquoteElement = xpathResult.singleNodeValue
  return false unless blockquoteElement?

  div = emailDocument.createElement('div')

  parent = blockquoteElement.parentElement
  parent.removeChild(blockquoteElement)
  return true

exports.cutById = (emailDocument) ->
  found = false
  for quoteId in QUOTE_IDS
    quoteElement = emailDocument.getElementById(quoteId)
    if quoteElement?
      found = true
      quoteElement.parentElement.removeChild(quoteElement)

  return found

exports.cutFromBlock = (emailDocument) ->
  # Handle case where From: block is enclosed in a tag
  xpathQuery = "//*[starts-with(normalize-space(.), 'From:')]|//*[starts-with(normalize-space(.), 'Date:')]"
  xpathResult = emailDocument.evaluate(xpathQuery, emailDocument, null, 5, null)

  # Find last element in iterator
  while fromBlock = xpathResult.iterateNext()
    lastBlock = fromBlock

  if lastBlock?
    # Find parent div and remove from document
    while lastBlock? && lastBlock.parentElement?
      if lastBlock.tagName == 'div'
        lastBlock.parentElement.removeChild(lastBlock)
        return true
      else
        lastBlock = lastBlock.parentElement
  else
    # Handle the case when From: block goes right after e.g. <hr> and is not enclosed in a tag itself
    xpathQuery = "//text()[starts-with(normalize-space(.), 'From:')]|//text()[starts-with(normalize-space(.), 'Date:')]"
    xpathResult = emailDocument.evaluate(xpathQuery, emailDocument, null, 9, null)

    # The text node that is the result
    textNode = xpathResult.singleNodeValue
    return false unless textNode?

    # The previous sibling stopped the initial xpath query from working, so it is likely a splitter (like an hr)
    splitterElement = textNode.previousSibling
    splitterElement?.parentElement?.removeChild(splitterElement)

    # Remove all subsequent siblings of the textNode
    afterSplitter = textNode.nextSibling
    while afterSplitter?
      afterSplitter.parentNode.removeChild(afterSplitter)
      afterSplitter = textNode.nextSibling

    textNode.parentNode.removeChild(textNode)
    return true

  return false

BREAK_TAG_REGEX = new RegExp('<br\\s*[/]?>', 'gi')

exports.replaceBreakTagsWithLineFeeds = (emailDocument) ->
  currentHtml = emailDocument.body.innerHTML
  emailDocument.body.innerHTML = currentHtml.replace BREAK_TAG_REGEX, "\n"

findMicrosoftSplitter = (emailDocument) ->
  # Outlook 2007, 2010
  query = "div[style='border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0cm 0cm 0cm']"
  splitterResult = emailDocument.querySelectorAll(query)

  if splitterResult.length == 0
    # Windows mail
    query = "div[style='padding-top: 5px; border-top-color: rgb(229, 229, 229); border-top-width: 1px; border-top-style: solid;']"
    splitterResult = emailDocument.querySelectorAll(query)

  if splitterResult.length > 0
    splitterElement = splitterResult[0]
    # Outlook 2010
    if splitterElement.parentElement? && splitterElement == splitterElement.parentElement.chilren[0]
      splitterElement = splitterElement.parentElement

    return splitterElement

  # Outlook 2003
  xpathQuery = "//div/div[@class='MsoNormal' and @align='center' and @style='text-align:center']/font/span/hr[@size='3' and @width='100%' and @align='center' and @tabindex='-1']"
  xpathResult = emailDocument.evaluate(xpathQuery, emailDocument, null, 9, null)
  splitterElement = xpathResult.singleNodeValue

  # Go up the tree to find the enclosing div.
  if splitterElement?
    splitterElement = splitterElement.parentElement.parentElement
    splitterElement = splitterElement.parentElement.parentElement

  return splitterElement

#  //div/div[@class='MsoNormal' and @align='center' and @style='text-align:center']/font/span/hr[@size='3' and @width='100%' and @align='center' and @tabindex='-1']"

removeNodes = (nodesArray) ->
  for index in [nodesArray.length - 1..0]
    node = nodesArray[index]
    node?.parentNode?.removeChild node

ensureTextNodeBetweenChildElements = (element) ->
  dom = element.ownerDocument
  currentNode = element.childNodes[0]

  while currentNode.nextSibling
    # An element is followed by an element
    if currentNode.nodeType == 1 && currentNode.nextSibling.nodeType == 1
      newTextNode = dom.createTextNode(' ');
      element.insertBefore(newTextNode, currentNode.nextSibling)
    currentNode = currentNode.nextSibling
