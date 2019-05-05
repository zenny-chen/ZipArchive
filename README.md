
[![Build Status](https://travis-ci.org/ZipArchive/ZipArchive.svg?branch=master)](https://travis-ci.org/ZipArchive/ZipArchive)

# SSZipArchive

ZipArchive is a simple utility class for zipping and unzipping files on iOS, macOS and tvOS.

- Unzip zip files;
- Unzip password protected zip files;
- Unzip AES encrypted zip files;
- Create zip files;
- Create password protected zip files;
- Create AES encrypted zip files;
- Choose compression level;
- Append to existing zip files;
- Zip-up NSData instances. (with a filename)

## What are modified

ZipArchive here can run on most of Unix-like systems besides macOS/iOS. If you're using Linux such as Ubuntu. You should install zlib and BSD library. Using the following commands will simply fulfill it for Debian-like operating systems.

```
sudo apt-get install zlib1g-dev
sudo apt-get install libbsd-dev
```

Note that don't forget to link the **BSD library** with `-lbsd` and link the **zlib library** with `-lz`.

<br />

Also, here added a legacy version which can work on single-chip devices such as Raspberry Pi. The folder **ZipArchive** is the whole complete sources and **legacy_main.m** is the usage demo.

As to the legacy version, there is no need to add the **BSD library**. It is just simple.

## Installation and Setup

*The main release branch is configured to support Objective C and Swift 3+.*

SSZipArchive works on Xcode 7-9 and above, iOS 8-11 and above.

### CocoaPods
In your Podfile:  
`pod 'SSZipArchive'`

### Carthage
In your Cartfile:  
`github "ZipArchive/ZipArchive"`

### Manual

1. Add the `SSZipArchive` and `minizip` folders to your project.
2. Add the `libz` library to your target

SSZipArchive requires ARC.

## Usage

### Objective-C

```objective-c
// Create
[SSZipArchive createZipFileAtPath:zipPath withContentsOfDirectory:sampleDataPath];

// Unzip
[SSZipArchive unzipFileAtPath:zipPath toDestination:unzipPath];
```

### Swift

```swift
// Create
SSZipArchive.createZipFileAtPath(zipPath, withContentsOfDirectory: sampleDataPath)

// Unzip
SSZipArchive.unzipFileAtPath(zipPath, toDestination: unzipPath)
```

## License

SSZipArchive is protected under the [MIT license](https://github.com/samsoffes/ssziparchive/raw/master/LICENSE) and our slightly modified version of [Minizip](https://github.com/nmoinvaz/minizip) 1.2 is licensed under the [Zlib license](http://www.zlib.net/zlib_license.html).

## Acknowledgments

* Big thanks to [aish](http://code.google.com/p/ziparchive) for creating [ZipArchive](http://code.google.com/p/ziparchive). The project that inspired SSZipArchive.
* Thank you [@soffes](https://github.com/soffes) for the actual name of SSZipArchive.
* Thank you [@randomsequence](https://github.com/randomsequence) for implementing the creation support tech.
* Thank you [@johnezang](https://github.com/johnezang) for all his amazing help along the way.
