# Markdown Renderer Test Document

This is a sample document to test all currently supported markdown elements in the static renderer.

## Paragraphs

This is a simple paragraph with some text. It should wrap properly at the configured width. Let's add more text to make it longer and see how the wrapping behaves with different content.

Here is another paragraph after a blank line. Paragraphs should have proper spacing between them.

## Inline Formatting

This paragraph has **bold text** and *italic text* and ***bold italic text*** mixed together.

You can also use __underscores for bold__ and _underscores for italic_ though *asterisks* are more common.

Here is some `inline code` within a sentence. You can use it for `function_names()` or `variable_names`.

## Links and Images

Visit [the Lilush repository](https://github.com/example/lilush) for more information.

Here's a link with a title: [Example Site](https://example.com "Example Title").

Multiple links in one line: [First](https://first.com) and [Second](https://second.com) and [Third](https://third.com).

Images work similarly: ![Alt text for image](https://example.com/image.png)

## Headings

### Level 3 Heading

Some content under a level 3 heading.

#### Level 4 Heading

Content under level 4.

##### Level 5 Heading

Content under level 5.

###### Level 6 Heading

The deepest heading level.

## Code Blocks

Here's a simple code block without a language:

```
plain code block
no syntax highlighting
just monospace text
```

And here's a code block with a language specified:

```lua
-- Lua code example
local function greet(name)
    print("Hello, " .. name .. "!")
end

greet("World")
```

Another example with Python:

```python
def fibonacci(n):
    if n <= 1:
        return n
    return fibonacci(n-1) + fibonacci(n-2)

for i in range(10):
    print(fibonacci(i))
```

Code blocks preserve indentation:

```
    indented line (4 spaces)
        more indented (8 spaces)
no indent
```

## Thematic Breaks

Content before the break.

---

Content after the first break.

***

Content after the second break.

___

Content after the third break.

## Mixed Content

### Code in Context

When writing Lua code, you might use the `require()` function to load modules:

```lua
local markdown = require("markdown")
local result = markdown.render(input, { width = 80 })
print(result)
```

The **markdown.render()** function accepts *options* including:
- `width` - the wrap width
- `indent` - global indentation
- `tss` - custom styling

Ordered list:

1. Always remember
1. The fifth
1. Of November!

### Links with Emphasis

Check out [**this bold link**](https://example.com) or [*this italic link*](https://example.com).

## Edge Cases

Empty code block:

```
```

Heading with **bold** and *italic* and `code`:

### Styled *Heading* with **bold** and `code`

Very long line without spaces to test non-wrapping 

---

End of test document.
