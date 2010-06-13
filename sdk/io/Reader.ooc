import text/Buffer

/**
   The reader interface provides a medium-indendant way to read characters
   from a source, e.g. a file, a string, an URL, etc.
   
   :author: Amos Wenger (nddrylliog)
   :author: Scott Olson (tsion / _scott)
   :author: Joshua Roesslein (joshthecoder)
 */
Reader: abstract class {
    
    /** Position in the stream. Not suppoted by all reader types */
    marker: Long

    /**
       Read 'count' bytes and store them in 'chars' with offset 'offset'
       :return: The number of bytes read
     */
    read: abstract func(chars: Char*, offset: Int, count: Int) -> SizeT
    
    /**
       Read a single character, and return int
     */
    read: abstract func ~char -> Char

    /**
       Read the stream until character `end` is reached, and return
       the result
     */
    readUntil: func (end: Char) -> String {
        sb := Buffer new(40) // let's be optimistic
        while(hasNext()) {
            c := read()
            if(c == end) break
            sb append(c)
        }
        return sb toString()
    }

    /**
       Read a single line and return it.
       
       More specifically, read until a '\n', trim any '\r' character
       and return the result
     */
    readLine: func -> String {
        readUntil('\n') trimRight('\r')
    }

    /**
       Attempts to read one character and then rewind the stream
       by one.
        
       If the underlying reader doesn't support rewinding, this may
       result in a runtime exception.
     */
    peek: func -> Char {
        c := read()
        rewind(1)
        return c
    }

    /**
       Read as many `unwanted` chars as 
     */
    skipWhile: func (unwanted: Char) {
        while(hasNext()) {
            c := read()
            if(c != unwanted) {
                rewind(1)
                break
            }
        }
    }

    /**
       :return: true if there's some more data to be read, false if
       we're at end-of-file.
        
       Note that it doesn't guarantee that any data is *ready* to be read.
       calling read() just after hasNext() has returned true may well
       return 0, depending on which kind of reader you're dealing with.
     */
    hasNext: abstract func -> Bool
    
    /**
       Attempt to rewind this stream by the given offset.
     */
    rewind: abstract func (offset: Int)
    
    /**
       Set the mark of this stream to the current position,
       and return it as a long.
     */
    mark: abstract func -> Long
    
    /**
       Attempt to reset the stream to the given mark
     */
    reset: abstract func (marker: Long)
    
    /**
       Skip the given number of bytes.
       If `offset` is negative, we will attempt to rewind the stream
     */
    skip: func(offset: Int) {
        if (offset < 0) {
            rewind(-offset)
        }
        else {
            for (i: Int in 0..offset) read()
        }
    }
    
    /**
       Close this reader and free the associated system resources, if any.
     */
    close: abstract func
    
}
