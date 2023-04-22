+++
title = "Constructing Highly Configurable Objects - The Builder Pattern"
date = 2023-04-30

[taxonomies]
tags = ["c++", "design-pattern", "builder"]
+++

## The Problem

In the last article [Create And Provide](00001-create-and_provide.md) we talked
about how to construct a C++ abstraction for `File`. It was a very minimalistic
wrapper where only the file name was provided and the file was created.

```cxx
class File {
  public:
    static std::optional<file> create(const std::string& path);
};
```

Often we would like to configure the object we are going to create in detail.
In the case of the file we may want to set the user- and group owner, fill
it with some content right when we have created it, set access permissions,
or delete it when it is already present and replace it with our
version.

When this is all stuffed inside one function it gets messy.

```cxx
class File {
  public:
    static std::optional<file> create(const std::string& path,
                                      const std::string& user,
                                      const std::string& group,
                                      const std::string& initial_content,
                                      const std::filesystem::perms permissions,
                                      const bool remove_existing_file);
};
```

When such a construct is used in production code one has to put in some real
effort to produce readable code. And four different arguments with the same
type can be confused easily.

```cxx
auto file = File::create("blueberry.md", "darth-banana", "hasselhoff", 
                         "looking-for-freedom", 
                         perms::owner_read | perms::owner_write, true);
```

When reading this code as a reviewer one has no idea what value corresponds with
what argument. Is `hasselhoff` now the content or the group or the user? What
does `true` stand for in this context? And what if I do not want to set a custom
user, group and initial content but only some permissions?

This is where the Builder Creation Pattern comes in. The rough idea is that we
introduce an additional class where we configure everything we want and then
call `create` and the configured thing will be constructed.

## The Builder Pattern

The most basic builder pattern consists of two classes, the class itself and
a builder class that can construct it. The builder class has the task to collect
all the settings and create the corresponding class based on the provided
configuration.
In the case of the `File` a class diagram may look like this.

```
+---------------------------------+
| FileBuilder                     |           +---------------------+
+ - - - - - - - - - - - - - - - - +           | File                |
| + user(string)                  |           + - - - - - - - - - - +
| + group(string)                 |  create   | + read() -> string  |
| + permission(filesystem::perms) |---------->| + write(string)     |
| + initial_content(string)       |           | - File(int)         |
| + remove_existing_file(bool)    |           |                     |
| + create(string)                |           | - fd                |
+---------------------------------+           +---------------------+
```

In this diagram the constructor of the `File` is private and the `FileBuilder`
would be the only instance allowed to access it to construct a new `File`.
