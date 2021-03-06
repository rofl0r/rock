import io/Reader, io/File

fopen: extern func(filename: Char*, mode: Char*) -> FILE*
fread: extern func(ptr: Pointer, size: SizeT, count: SizeT, stream: FILE*) -> SizeT
ferror: extern func(stream: FILE*) -> Int
feof: extern func(stream: FILE*) -> Int
fseek: extern func(stream: FILE*, offset: Long, origin: Int) -> Int
SEEK_CUR, SEEK_SET, SEEK_END: extern Int
ftell: extern func(stream: FILE*) -> Long

FileReader: class extends Reader {

    file: FILE*

    init: func ~withFile (fileObject: File) {
        init (fileObject getPath())
    }

    init: func ~withName (fileName: String) {
        init (fileName, "r")
    }

    init: func ~withMode (fileName, mode: String) {
        file = fopen(fileName, mode)
        if (!file)
            Exception new(This, "File not found: " + fileName) throw()
    }

    read: func(chars: Char*, offset: Int, count: Int) -> SizeT {
        fread(chars + offset, 1, count, file)
    }

    read: func ~char -> Char {
        value: Char
        if(fread(value&, 1, 1, file) != 1 && ferror(file)) {
            Exception new(This, "Error reading char from file") throw()
        }
        return value
    }

    hasNext?: func -> Bool {
        return feof(file) == 0
    }

    rewind: func(offset: Int) {
        fseek(file, -offset, SEEK_CUR)
    }

    mark: func -> Long {
        marker = ftell(file)
        return marker
    }

    reset: func(marker: Long) {
        fseek(file, marker, SEEK_SET)
    }

    close: func {
        fclose(file)
    }

}
