+++
title = "Create And Provide - Why You Shouldn't Create In The Constructor."
date = 2023-04-24

[taxonomies]
tags = ["c++", "raii", "posix"]
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

class File {
   public:
    File(const std::string& path) {
        this->fd = open(path.c_str(), O_EXCL | O_CREAT);
        if (this->fd == -1) {
            throw std::runtime_error("failed to create file");
        }
    }

    // read and write operations

    ~File() {
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
Creating a file that already exists is far from exceptional and should be
handled differently, for instance with the approach drafted in this article.
If it is impossible to recover from an error an exception is the right error
strategy, for instance when accessing an out-of-bounds element inside a
`std::vector` which could lead to a segmentation fault.

## The Bad Solution

The exception-less implementations I have seen often use an additional variable
to signal to the user if a construction was successful or not. So a variable
named `construction_successful` is introduced and provided to the constructor
as a reference.

```cpp
class File {
   public:
    File(const std::string & path, bool & construction_successful) {
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
File my_file(construction_successful);
if (!construction_successful) // perform error handling
```

But this introduces now several problems. The destructor of the file does not
know that the construction failed and still tries to destroy the object which
will now cause a call to the non-recoverable error handling mechanism `PANIC`.
Also, what happens when the user forgets to handle the error and continues working
on the file as if the construction was successful? So one has no other choice but
to store the variable `construction_successful` as an additional member and
check it in every operation like `read` and `write` - which is horrible.

Of course, we could remove these checks for `read` and `write`, let it be
undefined behavior, and define the contract in a way that the user must verify
`construction_successful` after construction. But there is one thing no one
likes in autonomous machines - it is undefined behavior! In a safety-critical
machine, you have ideally zero operations with potentially undefined behavior so
we have to perform these checks in `read` and `write`.

Now we have created a file abstraction:

* which has an invalid state,
* has a performance overhead in every method,
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

class File {
   public:
    static std::optional<File> create(const std::string& path) {
        int fd = open(path.c_str(), O_EXCL | O_CREAT);

        if (fd == -1) {
            return std::nullopt;
        }

        return std::make_optional<File>(fd);
    }

    // the constructor requires now only the actual resource, 
    // the file descriptor
    explicit File(const int fd) : fd{fd} {}
// ...
```

The `create` method returns either a `std::nullopt` when the construction
failed or the file packed inside an optional. We use `std::make_optional<File>`
to construct a new file and forward the file descriptor `fd` to the `File`s
constructor.

By constructing the underlying resources outside of the
class we removed all problems of the previous approach where we constructed
the file descriptor inside the constructor.

* This file variant is always valid - no longer nullable.
* No performance overhead in methods like `read` and `write`.
* It is even easier to test since we only have to check one function `create`
    for failure instead of every method.
* The error handling overhead is reduced for the user and the implementer.

To be fair, this approach does not apply to all kinds of resources out of the
box. A file
descriptor can always be copied and moved around but what if we have to deal
with handles to mutex or semaphores? A `pthread_mutex_t` should never be copied
or moved during the lifetime of the resource!

## Dealing With Non-Movable Resources

### Using `std::unique_ptr`

Let's stick with the `File` example and we assume that the file descriptor `fd`
is not allowed to be copied or moved after the `open` call was executed
successfully. The easiest thing we can do is to pack the file descriptor into a
`std::unique_ptr`, then it has a fixed memory position on the heap.

```cpp
class File {
   // ...

  private:
    std::unique_ptr<int> fd;
};
```

We modify the `create` method so that the return value of `open` is used to
initialize the file descriptor on the heap.

```cpp
class File {
    static std::optional<File> create(const std::string& path) {
        auto fd = std::make_unique<int>(open(path.c_str(), O_EXCL | O_CREAT));

        if (*fd == -1) {
            return std::nullopt;
        }

        return std::make_optional<File>(std::move(fd));
    }
```

Finally, we have to adjust the `File`s constructor so that it can handle the
unique pointer.

```cpp
class File {
    File(std::unique_ptr<int> && fd) : fd{std::move(fd)} {} 
}
```

In a safety-critical domain, the usage of heap memory is often forbidden since
we have to guarantee the availability of memory at all times. Therefore, all
the required memory either resides on the stack or is allocated once during
startup time.
In this particular case, the `File` is also a system resource, and in the context
of a safety-critical domain, it would make sense to create this also at startup
time which would mitigate the problem of the heap allocation. Either we have
enough memory available or we fail during startup.
Nevertheless, let's assume we want to use our custom allocator.

### Using `std::unique_ptr` With A Custom Allocator

The `Allocator` may have a simple interface to allocate and deallocate
memory.

```cxx
class Allocator {             
   public:                    
    template <typename T>     
    T* allocate();
    template <typename T>     
    void deallocate(T* ptr);
};                            
```

We modify the `create` method so that we provide a pointer to the allocator
additionally.

```cpp
class File {                                                          
   public:                                                            
    static std::optional<File> create(const std::string& path,        
                                      Allocator* const allocator) {   
        // acquire memory
        auto ptr_to_fd = allocator->allocate<int>();                  
        // placement new inside the allocated memory
        new (ptr_to_fd) int(open(path.c_str(), O_EXCL | O_CREAT));    

        // add std::function<void(int*)> as custom deleter
        std::unique_ptr<int, std::function<void(int*)>> fd(ptr_to_fd, 
            // release the memory
            [=](auto ptr) { allocator->deallocate(ptr); });
                                                                      
        if (*fd == -1) {                                              
            return std::nullopt;                                      
        }                                                             
                                                                      
        return std::make_optional<File>(std::move(fd));               
    }                                                                 
```

The function starts by allocating memory for the file descriptor,
initializing it with `open` as usual but in this case, we use placement new
to create the file descriptor in the previously allocated memory.

We add a custom deleter to the `std::unique_ptr` and define it with the
closure `[=](auto ptr) { allocator->deallocate(ptr); }` that releases the
memory in the allocator. Here we have to be cautious since the allocator must
at least live as long as the created resource otherwise
the `std::unique_ptr` accesses a dead object when it goes out of scope!

Since the allocator type is part of the `std::unique_ptr` type we have to adjust
the member type as well and are done.

```cpp
class File {
  private:
    std::unique_ptr<int, std::function<void(int*)>> fd;
};
```

## Summary

When dealing with failing constructors in an environment without exceptions an
approach like "Create And Provide" can help you to implement RAII cleanly. The
main idea is to create all the underlying handles and resources outside of the
class, in a free function and provide these successfully created handles to
the object itself.
The object then takes care of the resource's lifetimes and is always in a valid
state.
