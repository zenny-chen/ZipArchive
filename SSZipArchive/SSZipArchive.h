//
//  SSZipArchive.h
//  SSZipArchive
//
//  Created by Sam Soffes on 7/21/10.
//  Copyright (c) Sam Soffes 2010-2015. All rights reserved.
//

#ifndef _SSZIPARCHIVE_H
#define _SSZIPARCHIVE_H

#import <Foundation/Foundation.h>
#include "SSZipCommon.h"

#ifndef __clang__

#ifndef _Nonnull
#define _Nonnull
#endif

#ifndef _Nullable
#define _Nullable
#endif

#endif

#ifndef NS_UNAVAILABLE
#define NS_UNAVAILABLE
#endif

enum SSZipArchiveErrorCode {
    SSZipArchiveErrorCodeFailedOpenZipFile      = -1,
    SSZipArchiveErrorCodeFailedOpenFileInZip    = -2,
    SSZipArchiveErrorCodeFileInfoNotLoadable    = -3,
    SSZipArchiveErrorCodeFileContentNotReadable = -4,
    SSZipArchiveErrorCodeFailedToWriteFile      = -5,
    SSZipArchiveErrorCodeInvalidArguments       = -6,
};

@protocol SSZipArchiveDelegate;

@interface SSZipArchive : NSObject
{
@private
    
    /// path for zip file
    NSString *_path;
    void *_zip;
}

// Password check
+ (BOOL)isFilePasswordProtectedAtPath:(NSString *)path;
+ (BOOL)isPasswordValidForArchiveAtPath:(NSString *)path password:(NSString *)pw error:(NSError **)error;

// Unzip
+ (BOOL)unzipFileAtPath:(NSString* _Nonnull)path toDestination:(NSString* _Nonnull)destination;
+ (BOOL)unzipFileAtPath:(NSString* _Nonnull)path toDestination:(NSString* _Nonnull)destination delegate:(id<SSZipArchiveDelegate>)delegate;

+ (BOOL)unzipFileAtPath:(NSString* _Nonnull)path
          toDestination:(NSString* _Nonnull)destination
              overwrite:(BOOL)overwrite
               password:(NSString* _Nullable)password
                  error:(NSError* _Nonnull * _Nonnull)error;

+ (BOOL)unzipFileAtPath:(NSString *)path
          toDestination:(NSString *)destination
              overwrite:(BOOL)overwrite
               password:(NSString* _Nullable)password
                  error:(NSError* _Nullable * _Nullable)error
               delegate:(id<SSZipArchiveDelegate>)delegate;

+ (BOOL)unzipFileAtPath:(NSString* _Nonnull)path
          toDestination:(NSString* _Nonnull)destination
     preserveAttributes:(BOOL)preserveAttributes
              overwrite:(BOOL)overwrite
               password:(NSString* _Nullable)password
                  error:(NSError* _Nullable * _Nullable)error
               delegate:(id<SSZipArchiveDelegate>)delegate;

// Zip
// default compression level is Z_DEFAULT_COMPRESSION (from "zlib.h")

// without password
+ (BOOL)createZipFileAtPath:(NSString* _Nonnull)path withFilesAtPaths:(NSArray* _Nonnull)paths;
+ (BOOL)createZipFileAtPath:(NSString* _Nonnull)path withContentsOfDirectory:(NSString* _Nonnull)directoryPath;

+ (BOOL)createZipFileAtPath:(NSString* _Nonnull)path withContentsOfDirectory:(NSString* _Nonnull)directoryPath keepParentDirectory:(BOOL)keepParentDirectory;

// with optional password, default encryption is AES
// don't use AES if you need compatibility with native macOS unzip and Archive Utility
+ (BOOL)createZipFileAtPath:(NSString* _Nonnull)path withFilesAtPaths:(NSArray* _Nonnull)paths withPassword:(NSString* _Nullable)password;
+ (BOOL)createZipFileAtPath:(NSString* _Nonnull)path withContentsOfDirectory:(NSString * _Nonnull)directoryPath withPassword:(NSString* _Nullable)password;
+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString* _Nonnull)directoryPath keepParentDirectory:(BOOL)keepParentDirectory withPassword:(NSString* _Nullable)password;

/// This initializer is unavailable
- (SSZipArchive*)init NS_UNAVAILABLE;
- (SSZipArchive*)initWithPath:(NSString *)path;
- (BOOL)open;

/// write empty folder
- (BOOL)writeFolderAtPath:(NSString* _Nonnull)path withFolderName:(NSString* _Nonnull)folderName withPassword:(NSString* _Nullable)password;
/// write file
- (BOOL)writeFile:(NSString* _Nonnull)path withPassword:(NSString* _Nullable)password;
- (BOOL)writeFileAtPath:(NSString* _Nonnull)path withFileName:(NSString* _Nullable)fileName withPassword:(NSString* _Nullable)password;
- (BOOL)writeFileAtPath:(NSString* _Nonnull)path withFileName:(NSString* _Nullable)fileName compressionLevel:(int)compressionLevel password:(NSString* _Nullable)password AES:(BOOL)aes;
/// write data
- (BOOL)writeData:(NSData* _Nonnull)data filename:(NSString* _Nullable)filename withPassword:(NSString* _Nullable)password;
- (BOOL)writeData:(NSData* _Nonnull)data filename:(NSString* _Nullable)filename compressionLevel:(int)compressionLevel password:(NSString* _Nullable)password AES:(BOOL)aes;

- (BOOL)close;

@end

@protocol SSZipArchiveDelegate <NSObject>

@optional

- (void)zipArchiveWillUnzipArchiveAtPath:(NSString *)path zipInfo:(unz_global_info)zipInfo;
- (void)zipArchiveDidUnzipArchiveAtPath:(NSString *)path zipInfo:(unz_global_info)zipInfo unzippedPath:(NSString *)unzippedPath;

- (BOOL)zipArchiveShouldUnzipFileAtIndex:(NSInteger)fileIndex totalFiles:(NSInteger)totalFiles archivePath:(NSString *)archivePath fileInfo:(unz_file_info)fileInfo;
- (void)zipArchiveWillUnzipFileAtIndex:(NSInteger)fileIndex totalFiles:(NSInteger)totalFiles archivePath:(NSString *)archivePath fileInfo:(unz_file_info)fileInfo;
- (void)zipArchiveDidUnzipFileAtIndex:(NSInteger)fileIndex totalFiles:(NSInteger)totalFiles archivePath:(NSString *)archivePath fileInfo:(unz_file_info)fileInfo;
- (void)zipArchiveDidUnzipFileAtIndex:(NSInteger)fileIndex totalFiles:(NSInteger)totalFiles archivePath:(NSString *)archivePath unzippedFilePath:(NSString *)unzippedFilePath;

- (void)zipArchiveProgressEvent:(uint64_t)loaded total:(uint64_t)total;

@end

#endif /* _SSZIPARCHIVE_H */

