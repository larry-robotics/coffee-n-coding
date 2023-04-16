+++
title = "Construct And Provide - Why You Shouldn't Construct In The Constructor."
date = 2023-04-16

[taxonomies]
tags = ["c++", "design-pattern", "builder"]
+++

## The problem

When writing code in C++ for safety-critical applications one is facing
numerous challenges and one of them is that exceptions are forbidden. I do
not want to question the ban of exceptions itself but rather show how to cleanly
construct objects when the constructor can fail. The standard approach is to
throw an exception but what to do if this is off the table?

Let's assume we would like to create a C++ abstraction for a POSIX file. We
use `open` to create a new file and `close` to release the file descriptor.
A first implementation with exceptions may look like this:

```cpp
#include <fcntl.h>
#include <unistd.h>

#include <iostream>
#include <stdexcept>
#include <string>

#define PANIC(msg)

class file {
   public:
    file(const std::string& path) {
        this->fd = open(path.c_str(), O_EXCL | O_CREAT);
        if (this->fd == -1) {
            throw std::runtime_error("failed to create file");
        }
    }

    // read and write operations

    ~file() {
        if (close(this->fd) == -1) {
            PANIC("This should never happen. Unable to close file descriptor.");
        }
    }

   private:
    int fd{-1};
};
```

**Side Note:** Please use exceptions only for exceptional cases. This code throws
a `std::runtime_error` to just illustrate the problem.
Creating a file which already exists is far from being exceptional and should be
handled in a different way.
If it is impossible to recover from an error an exception is the right error
strategy, for instance when accessing an out-of-bounds element inside a
`std::vector` which could lead to a segmentation fault.

## The Bad Solution

The exception-less implementations I have seen often use an additional variable
to signal to the user if a construction was successful or not. So a variable
named `construction_successful` is introduced and provided to the constructor
as reference.

```cpp
class file {
   public:
    file(const std::string & path, bool & construction_successful) {
        construction_successful = true;
        this->fd = open(path.c_str(), O_EXCL | O_CREAT);
        if (this->fd == -1) {
            construction_successful = false;
        }
    }

    //...
}
```

The user now knows when the file construction failed and can take measures. Like
this:

```cpp
bool construction_successful = false;
file my_file(construction_successful);
if (!construction_successful) // perform error handling
```

But this introduces now several problems. The destructor of the file does not
know that the construction failed and still tries to destroy the object which
will now cause a call to the non-recoverable error handling mechanism `PANIC`.
Also, what happens when the user forgets to handle the error and continues working
on the file as if the construction was successful? So one has no other choice but
to store the variable `construction_successful` as an additional member and
check it in every operation like `read` and `write` - which is horrible.

Of course we could remove these checks for `read` and `write`, let it be
undefined behavior, and define the contract in a way that the user must verify
`construction_successful` after construction. But there is one thing no one
likes in an autonomous machines - it is undefined behavior! In a safety-critical
machine you have ideally zero operations with potentially undefined behavior so
we have to perform these checks in `read` and `write`.

Now we have created a file abstraction:
 * which has an invalid state,
 * has performance overhead in every method,
 * has massive test overhead - every method has to be verified that the error
    case "construction not successful" is handled correctly,
 * has massive error handling overhead - the user and implementer have to
    handle calls to methods when the object is in an invalid state

## The Good Solution: Create And Provide

Did you ever realize that `std::unique_ptr` or `std::shared_ptr`, the prime
examples of RAII, do not create the memory they own and manage? Either one
has to use a construct like `std::make_unique` or calls the constructor
directly and provide the memory with `new` like
`auto ptr = std::unique_ptr<int>(new int(1))`.

We should do the same thing here. Create our object, the initialized file
descriptor, outside of the class and provide it to the constructor.
This can be done in a static method `create` for instance.

```cpp
#include <optional>

class file {
   public:
    static std::optional<file> create(const std::string& path) {
        int fd = open(path.c_str(), O_EXCL | O_CREAT);

        if (fd == -1) {
            return std::nullopt;
        }

        return std::make_optional<file>(fd);
    }

// ...
```

The `create` method returns either a `std::nullopt` when the construction
failed or the file packed inside an optional.

By constructing the underlying resources outside of the
class we removed all problems of the previous approach were we constructed
the file descriptor inside the constructor.

 * This file variant is always valid - no longer nullable.
 * No performance overhead in methods like `read` and `write`.
 * It is even easier testable since we only have to check one function `create`
    for failure instead of every method.
 * The error handling overhead is reduced for the user and the implementer.

To be fair, this approach is not applicable to all kind of resources. It assumes
that the underlying resource is at least movable which is not the case for
the handles of a POSIX mutex or unnamed semaphores. We tackle his challenge and
the problem of a constructor with many arguments in the next blog article.

## Summary

When dealing with failing constructors in an environment without exceptions an
approach like "Create And Provide" can help you to implement RAII cleanly. The
main idea is to create all the underlying handles and resources outside of the
class, in a free function and provide these successfully created handles to
the object itself.
The object then takes care of the resources lifetimes and is always in a valid
state.
