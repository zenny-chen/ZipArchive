//
//  SSZipArchive.m
//  SSZipArchive
//
//  Created by Sam Soffes on 7/21/10.
//  Copyright (c) Sam Soffes 2010-2015. All rights reserved.
//

#import "SSZipArchive.h"
#include "unzip.h"
#include "zip.h"
#include "minishared.h"

#include <sys/stat.h>

NSString *const SSZipArchiveErrorDomain = @"SSZipArchiveErrorDomain";

#define CHUNK 16384

extern int _zipOpenEntry(zipFile entry, NSString *name, const zip_fileinfo *zipfi, int level, NSString *password, BOOL aes);
extern BOOL _fileIsSymbolicLink(const unz_file_info *fileInfo);

@interface NSData(SSZipArchive)
- (NSString *)_hexString;
@end

@interface NSString (SSZipArchive)
- (NSString *)_sanitizedPath;
@end

@implementation SSZipArchive

// MARK: Password check

+ (BOOL)isFilePasswordProtectedAtPath:(NSString *)path {
    // Begin opening
    zipFile zip = unzOpen(path.fileSystemRepresentation);
    if (zip == NULL)
        return NO;
    
    int ret = unzGoToFirstFile(zip);
    if (ret == UNZ_OK)
    {
        do
        {
            ret = unzOpenCurrentFile(zip);
            if (ret != UNZ_OK)
            {
                // attempting with an arbitrary password to workaround `unzOpenCurrentFile` limitation on AES encrypted files
                ret = unzOpenCurrentFilePassword(zip, "");
                unzCloseCurrentFile(zip);
                if (ret == UNZ_OK || ret == UNZ_BADPASSWORD)
                    return YES;

                return NO;
            }
            
            unz_file_info fileInfo = {};
            ret = unzGetCurrentFileInfo(zip, &fileInfo, NULL, 0, NULL, 0, NULL, 0);
            unzCloseCurrentFile(zip);
            if (ret != UNZ_OK)
                return NO;
            else if ((fileInfo.flag & 1) == 1)
                return YES;
            
            ret = unzGoToNextFile(zip);
        }
        while (ret == UNZ_OK);
    }

    return NO;
}

+ (BOOL)isPasswordValidForArchiveAtPath:(NSString *)path password:(NSString *)pw error:(NSError **)error
{
    zipFile zip = unzOpen(path.fileSystemRepresentation);
    if (zip == NULL)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:SSZipArchiveErrorDomain
                                         code:SSZipArchiveErrorCodeFailedOpenZipFile
                                     userInfo:[NSDictionary dictionaryWithObject:@"failed to open zip file" forKey:NSLocalizedDescriptionKey]];
        }
        
        return NO;
    }

    int ret = unzGoToFirstFile(zip);
    if (ret == UNZ_OK)
    {
        do
        {
            if (pw.length == 0)
                ret = unzOpenCurrentFile(zip);
            else
                ret = unzOpenCurrentFilePassword(zip, pw.UTF8String);
            
            if (ret != UNZ_OK)
            {
                if (ret != UNZ_BADPASSWORD)
                {
                    if (error != NULL)
                    {
                        *error = [NSError errorWithDomain:SSZipArchiveErrorDomain
                                                     code:SSZipArchiveErrorCodeFailedOpenFileInZip
                                                 userInfo:[NSDictionary dictionaryWithObject:@"failed to open first file in zip file" forKey:NSLocalizedDescriptionKey]];
                    }
                }
                
                return NO;
            }
            
            unz_file_info fileInfo = {};
            ret = unzGetCurrentFileInfo(zip, &fileInfo, NULL, 0, NULL, 0, NULL, 0);
            if (ret != UNZ_OK)
            {
                if (error != NULL)
                {
                    *error = [NSError errorWithDomain:SSZipArchiveErrorDomain
                                                 code:SSZipArchiveErrorCodeFileInfoNotLoadable
                                             userInfo:[NSDictionary dictionaryWithObject:@"failed to retrieve info for file" forKey:NSLocalizedDescriptionKey]];
                }
                
                return NO;
            }
            else if ((fileInfo.flag & 1) == 1)
            {
                uint8_t buffer[10] = {0};
                int readBytes = unzReadCurrentFile(zip, buffer, (unsigned)MIN(10UL, fileInfo.uncompressed_size));
                
                if (readBytes < 0)
                {
                    // Let's assume error Z_DATA_ERROR is caused by an invalid password
                    // Let's assume other errors are caused by Content Not Readable
                    if (readBytes != Z_DATA_ERROR)
                    {
                        if (error != NULL)
                        {
                            *error = [NSError errorWithDomain:SSZipArchiveErrorDomain
                                                         code:SSZipArchiveErrorCodeFileContentNotReadable
                                                     userInfo:[NSDictionary dictionaryWithObject:@"failed to read contents of file entry" forKey:NSLocalizedDescriptionKey]];
                        }
                    }
                    
                    return NO;
                }
                
                break;
            }
            
            unzCloseCurrentFile(zip);
            ret = unzGoToNextFile(zip);
        }
        while (ret == UNZ_OK);
    }
    
    if (error != NULL)
        *error = nil;
    
    // No password required
    return YES;
}

// MARK: Unzipping

+ (BOOL)unzipFileAtPath:(NSString *)path
                toDestination:(NSString *)destination
                preserveAttributes:(BOOL)preserveAttributes
                overwrite:(BOOL)overwrite
                nestedZipLevel:(int)nestedZipLevel
                password:(NSString *)password
                error:(NSError **)error
                delegate:(id<SSZipArchiveDelegate>)delegate
{
    // Guard against empty strings
    if (path.length == 0 || destination.length == 0)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"received invalid argument(s)" forKey:NSLocalizedDescriptionKey];
        NSError *err = [NSError errorWithDomain:SSZipArchiveErrorDomain code:SSZipArchiveErrorCodeInvalidArguments userInfo:userInfo];
        if (error != NULL)
            *error = err;
        
        return NO;
    }
    
    // Begin opening
    zipFile zip = unzOpen(path.fileSystemRepresentation);
    if (zip == NULL)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"failed to open zip file" forKey:NSLocalizedDescriptionKey];
        NSError *err = [NSError errorWithDomain:SSZipArchiveErrorDomain code:SSZipArchiveErrorCodeFailedOpenZipFile userInfo:userInfo];
        if (error != NULL)
            *error = err;

        return NO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:path error:nil];
    uint64_t fileSize = [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
    uint64_t currentPosition = 0;
    
    unz_global_info globalInfo = {};
    unzGetGlobalInfo(zip, &globalInfo);
    
    // Begin unzipping
    int ret = 0;
    ret = unzGoToFirstFile(zip);
    if (ret != UNZ_OK && ret != UNZ_END_OF_LIST_OF_FILE)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"failed to open first file in zip file" forKey:NSLocalizedDescriptionKey];
        NSError *err = [NSError errorWithDomain:SSZipArchiveErrorDomain code:SSZipArchiveErrorCodeFailedOpenFileInZip userInfo:userInfo];
        if (error != NULL)
            *error = err;
        
        return NO;
    }

    BOOL success = YES;
    BOOL canceled = NO;
    int crc_ret = 0;
    char buffer[4096] = { '\0' };

    NSMutableArray *directoriesModificationDates = NSMutableArray.array;

    // Message delegate
    if ([delegate respondsToSelector:@selector(zipArchiveWillUnzipArchiveAtPath:zipInfo:)])
        [delegate zipArchiveWillUnzipArchiveAtPath:path zipInfo:globalInfo];

    if ([delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)])
        [delegate zipArchiveProgressEvent:currentPosition total:fileSize];
    
    NSInteger currentFileNumber = -1;
    NSError *unzippingError = nil;
    do
    {
        currentFileNumber++;
        if (ret == UNZ_END_OF_LIST_OF_FILE)
            break;

        if (password.length == 0)
            ret = unzOpenCurrentFile(zip);
        else
            ret = unzOpenCurrentFilePassword(zip, [password cStringUsingEncoding:NSUTF8StringEncoding]);
        
        if (ret != UNZ_OK)
        {
            unzippingError = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:SSZipArchiveErrorCodeFailedOpenFileInZip userInfo:[NSDictionary dictionaryWithObject:@"failed to open file in zip file" forKey:NSLocalizedDescriptionKey]];
            success = NO;
            break;
        }
        
        // Reading data and write to file
        unz_file_info fileInfo;
        memset(&fileInfo, 0, sizeof(unz_file_info));
        
        ret = unzGetCurrentFileInfo(zip, &fileInfo, NULL, 0, NULL, 0, NULL, 0);
        if (ret != UNZ_OK)
        {
            unzippingError = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:SSZipArchiveErrorCodeFileInfoNotLoadable userInfo:[NSDictionary dictionaryWithObject:@"failed to retrieve info for file" forKey:NSLocalizedDescriptionKey]];
            success = NO;
            unzCloseCurrentFile(zip);
            break;
        }

        currentPosition += fileInfo.compressed_size;

        // Message delegate
        if ([delegate respondsToSelector:@selector(zipArchiveShouldUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)])
        {
            if (![delegate zipArchiveShouldUnzipFileAtIndex:currentFileNumber
                                                 totalFiles:(NSInteger)globalInfo.number_entry
                                                archivePath:path
                                                   fileInfo:fileInfo])
            {
                success = NO;
                canceled = YES;
                break;
            }
        }
        if ([delegate respondsToSelector:@selector(zipArchiveWillUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)])
        {
            [delegate zipArchiveWillUnzipFileAtIndex:currentFileNumber totalFiles:(NSInteger)globalInfo.number_entry
                                         archivePath:path fileInfo:fileInfo];
        }
        if ([delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)])
            [delegate zipArchiveProgressEvent:(NSInteger)currentPosition total:(NSInteger)fileSize];
        
        char *filename = malloc(fileInfo.size_filename + 1);
        if (filename == NULL)
        {
            success = NO;
            break;
        }
        
        unzGetCurrentFileInfo(zip, &fileInfo, filename, fileInfo.size_filename + 1, NULL, 0, NULL, 0);
        filename[fileInfo.size_filename] = '\0';
        
        BOOL fileIsSymbolicLink = _fileIsSymbolicLink(&fileInfo);
        
        NSString * strPath = [SSZipArchive _filenameStringWithCString:filename
                                                      version_made_by:fileInfo.version
                                                 general_purpose_flag:fileInfo.flag
                                                                 size:fileInfo.size_filename];
        if ([strPath hasPrefix:@"__MACOSX/"])
        {
            // ignoring resource forks: https://superuser.com/questions/104500/what-is-macosx-folder
            unzCloseCurrentFile(zip);
            ret = unzGoToNextFile(zip);
            free(filename);
            continue;
        }
        
        // Check if it contains directory
        BOOL isDirectory = NO;
        if (filename[fileInfo.size_filename - 1] == '/' || filename[fileInfo.size_filename-1] == '\\')
            isDirectory = YES;

        free(filename);

        // Sanitize paths in the file name.
        strPath = [strPath _sanitizedPath];
        if (strPath.length == 0)
        {
            // if filename data is unsalvageable, we default to currentFileNumber
            strPath = [NSNumber numberWithInteger:currentFileNumber].stringValue;
        }

        NSString *fullPath = [destination stringByAppendingPathComponent:strPath];
        NSError *err = nil;
        NSDictionary *directoryAttr = nil;
        
        if (preserveAttributes)
        {
            NSDate *modDate = [[self class] _dateWithMSDOSFormat:(uint32_t)fileInfo.dos_date];
            directoryAttr = [NSDictionary dictionaryWithObjectsAndKeys:modDate, NSFileCreationDate, modDate, NSFileModificationDate, nil];
            [directoriesModificationDates addObject:[NSDictionary dictionaryWithObjectsAndKeys:fullPath, @"path", modDate, @"modDate", nil]];
        }
        if (isDirectory)
            [fileManager createDirectoryAtPath:fullPath withIntermediateDirectories:YES attributes:directoryAttr error:&err];
        else
            [fileManager createDirectoryAtPath:fullPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:directoryAttr error:&err];
        
        if (err != nil)
        {
            if ([err.domain isEqualToString:NSCocoaErrorDomain] &&
                err.code == 640)
            {
                unzippingError = err;
                unzCloseCurrentFile(zip);
                success = NO;
                break;
            }
            
            NSLog(@"[SSZipArchive] Error: %@", err.localizedDescription);
        }
        
        if ([fileManager fileExistsAtPath:fullPath] && !isDirectory && !overwrite) {
            // FIXME: couldBe CRC Check?
            unzCloseCurrentFile(zip);
            ret = unzGoToNextFile(zip);
            continue;
        }
        
        if (isDirectory && !fileIsSymbolicLink)
        {
            // nothing to read/write for a directory
        }
        else if (!fileIsSymbolicLink)
        {
            // ensure we are not creating stale file entries
            int readBytes = unzReadCurrentFile(zip, buffer, 4096);
            if (readBytes >= 0)
            {
                FILE *fp = fopen(fullPath.fileSystemRepresentation, "wb");
                while (fp != NULL)
                {
                    if (readBytes > 0)
                    {
                        if (0 == fwrite(buffer, readBytes, 1, fp))
                        {
                            if (ferror(fp) != 0)
                            {
                                NSString *message = [NSString stringWithFormat:@"Failed to write file (check your free space)"];
                                NSLog(@"[SSZipArchive] %@", message);
                                success = NO;
                                unzippingError = [NSError errorWithDomain:@"SSZipArchiveErrorDomain" code:SSZipArchiveErrorCodeFailedToWriteFile userInfo:[NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]];
                                break;
                            }
                        }
                    }
                    else
                        break;
                    
                    readBytes = unzReadCurrentFile(zip, buffer, 4096);
                    if (readBytes < 0)
                    {
                        // Let's assume error Z_DATA_ERROR is caused by an invalid password
                        // Let's assume other errors are caused by Content Not Readable
                        success = NO;
                    }
                }

                if (fp != NULL)
                {
                    fclose(fp);

                    if(nestedZipLevel
                        && [fullPath.pathExtension.lowercaseString isEqualToString:@"zip"]
                        && [self unzipFileAtPath:fullPath
                                   toDestination:fullPath.stringByDeletingLastPathComponent
                              preserveAttributes:preserveAttributes
                                       overwrite:overwrite
                                  nestedZipLevel:nestedZipLevel - 1
                                        password:password
                                           error:nil
                                        delegate:nil])
                    {
                            [directoriesModificationDates removeLastObject];
                            [fileManager removeItemAtPath:fullPath error:nil];
                        
                    }
                    else if (preserveAttributes)
                    {
                        // Set the original datetime property
                        if (fileInfo.dos_date != 0)
                        {
                            NSDate *orgDate = [[self class] _dateWithMSDOSFormat:(uint32_t)fileInfo.dos_date];
                            NSDictionary *attr = [NSDictionary dictionaryWithObject:orgDate forKey:NSFileModificationDate];

                            if (attr != nil)
                            {
                                if (![fileManager changeFileAttributes:attr atPath:fullPath])
                                    NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting modification date");
                            }
                        }
                        
                        // Set the original permissions on the file (+read/write to solve #293)
                        uint32_t permissions = fileInfo.external_fa >> 16 | 0x0180;
                        if (permissions != 0)
                        {
                            // Store it into a NSNumber
                            NSNumber *permissionsValue = [NSNumber numberWithUnsignedInt:permissions];
                            
                            // Retrieve any existing attributes
                            NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithDictionary:[fileManager attributesOfItemAtPath:fullPath error:nil]];
                            
                            // Set the value in the attributes dict
                            [attrs setObject:permissionsValue forKey:NSFilePosixPermissions];
                            
                            // Update attributes
                            if (![fileManager changeFileAttributes:attrs atPath:fullPath]) {
                                // Unable to set the permissions attribute
                                NSLog(@"[SSZipArchive] Failed to set attributes - whilst setting permissions");
                            }
                        }
                    }
                }
                else
                {
                    // if we couldn't open file descriptor we can validate global errno to see the reason
                    if (errno == ENOSPC)
                    {
                        NSError *enospcError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                                   code:ENOSPC
                                                               userInfo:nil];
                        unzippingError = enospcError;
                        unzCloseCurrentFile(zip);
                        success = NO;
                        break;
                    }
                }
            }
            else
            {
                // Let's assume error Z_DATA_ERROR is caused by an invalid password
                // Let's assume other errors are caused by Content Not Readable
                success = NO;
                break;
            }
        }
        else
        {
            // Assemble the path for the symbolic link
            NSMutableString *destinationPath = NSMutableString.string;
            int bytesRead = 0;
            while ((bytesRead = unzReadCurrentFile(zip, buffer, 4096)) > 0)
            {
                buffer[bytesRead] = 0;
                [destinationPath appendString:[NSString stringWithUTF8String:buffer]];
            }
            if (bytesRead < 0)
            {
                // Let's assume error Z_DATA_ERROR is caused by an invalid password
                // Let's assume other errors are caused by Content Not Readable
                success = NO;
                break;
            }
            
            // Check if the symlink exists and delete it if we're overwriting
            if (overwrite)
            {
                if ([fileManager fileExistsAtPath:fullPath])
                {
                    NSError *error = nil;
                    BOOL removeSuccess = [fileManager removeItemAtPath:fullPath error:&error];
                    if (!removeSuccess)
                    {
                        NSString *message = [NSString stringWithFormat:@"Failed to delete existing symbolic link at \"%@\"", error.localizedDescription];
                        NSLog(@"[SSZipArchive] %@", message);
                        success = NO;
                        unzippingError = [NSError errorWithDomain:SSZipArchiveErrorDomain code:error.code userInfo:[NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]];
                    }
                }
            }

            // Create the symbolic link (making sure it stays relative if it was relative before)
            int symlinkError = symlink(destinationPath.UTF8String, fullPath.UTF8String);

            if (symlinkError != 0)
            {
                // Bubble the error up to the completion handler
                NSString *message = [NSString stringWithFormat:@"Failed to create symbolic link at \"%@\" to \"%@\" - symlink() error code: %d", fullPath, destinationPath, errno];
                NSLog(@"[SSZipArchive] %@", message);
                success = NO;
                unzippingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:symlinkError userInfo:[NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]];
            }
        }
        
        crc_ret = unzCloseCurrentFile(zip);
        if (crc_ret == UNZ_CRCERROR)
        {
            // CRC ERROR
            success = NO;
            break;
        }
        ret = unzGoToNextFile(zip);
        
        // Message delegate
        if ([delegate respondsToSelector:@selector(zipArchiveDidUnzipFileAtIndex:totalFiles:archivePath:fileInfo:)])
        {
            [delegate zipArchiveDidUnzipFileAtIndex:currentFileNumber totalFiles:(NSInteger)globalInfo.number_entry
                                        archivePath:path fileInfo:fileInfo];
        }
        else if ([delegate respondsToSelector: @selector(zipArchiveDidUnzipFileAtIndex:totalFiles:archivePath:unzippedFilePath:)])
        {
            [delegate zipArchiveDidUnzipFileAtIndex: currentFileNumber totalFiles: (NSInteger)globalInfo.number_entry
                                        archivePath:path unzippedFilePath: fullPath];
        }
    }
    while (ret == UNZ_OK && success);

    // Close
    unzClose(zip);

    // The process of decompressing the .zip archive causes the modification times on the folders
    // to be set to the present time. So, when we are done, they need to be explicitly set.
    // set the modification date on all of the directories.
    if (success && preserveAttributes)
    {
        NSError * err = nil;
        for (NSDictionary * d in directoriesModificationDates)
        {
            if (![fileManager changeFileAttributes:[NSDictionary dictionaryWithObject:[d objectForKey:@"modDate"] forKey:NSFileModificationDate] atPath:[d objectForKey:@"path"]])
                NSLog(@"[SSZipArchive] Set attributes failed for directory: %@.", [d objectForKey:@"path"]);

            if (err != nil)
                NSLog(@"[SSZipArchive] Error setting directory file modification date attribute: %@", err.localizedDescription);
        }
    }
    
    // Message delegate
    if (success && [delegate respondsToSelector:@selector(zipArchiveDidUnzipArchiveAtPath:zipInfo:unzippedPath:)])
        [delegate zipArchiveDidUnzipArchiveAtPath:path zipInfo:globalInfo unzippedPath:destination];

    // final progress event = 100%
    if (!canceled && [delegate respondsToSelector:@selector(zipArchiveProgressEvent:total:)])
        [delegate zipArchiveProgressEvent:fileSize total:fileSize];
    
    NSError *retErr = nil;
    if (crc_ret == UNZ_CRCERROR)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"crc check failed for file" forKey:NSLocalizedDescriptionKey];
        retErr = [NSError errorWithDomain:SSZipArchiveErrorDomain code:SSZipArchiveErrorCodeFileInfoNotLoadable userInfo:userInfo];
    }
    
    if (error != NULL)
    {
        if (unzippingError != nil)
            *error = unzippingError;
        else
            *error = retErr;
    }
    
    return success;
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination
{
    return [self unzipFileAtPath:path toDestination:destination delegate:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination delegate:(id<SSZipArchiveDelegate>)delegate
{
    return [self unzipFileAtPath:path toDestination:destination preserveAttributes:YES overwrite:YES password:nil error:nil delegate:delegate];
}

+ (BOOL)unzipFileAtPath:(NSString *)path toDestination:(NSString *)destination overwrite:(BOOL)overwrite password:(NSString*)password error:(NSError **)error
{
    return [self unzipFileAtPath:path toDestination:destination preserveAttributes:YES overwrite:overwrite password:password error:error delegate:nil];
}

+ (BOOL)unzipFileAtPath:(NSString *)path
          toDestination:(NSString *)destination
              overwrite:(BOOL)overwrite
               password:(NSString* )password
                  error:(NSError **)error
               delegate:(id<SSZipArchiveDelegate>)delegate
{
    return [self unzipFileAtPath:path toDestination:destination preserveAttributes:YES overwrite:YES password:password error:error delegate:delegate];
}

+ (BOOL)unzipFileAtPath:(NSString *)path
          toDestination:(NSString *)destination
     preserveAttributes:(BOOL)preserveAttributes
              overwrite:(BOOL)overwrite
               password:(NSString *)password
                  error:(NSError **)error
               delegate:(id<SSZipArchiveDelegate>)delegate
{
    return [self unzipFileAtPath:path toDestination:destination preserveAttributes:preserveAttributes overwrite:overwrite nestedZipLevel:0 password:password error:error delegate:delegate];
}

// MARK: Zipping

+ (BOOL)createZipFileAtPath:(NSString *)path withFilesAtPaths:(NSArray*)paths
{
    return [SSZipArchive createZipFileAtPath:path withFilesAtPaths:paths withPassword:nil];
}

+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath
{
    return [SSZipArchive createZipFileAtPath:path withContentsOfDirectory:directoryPath withPassword:nil];
}

+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath keepParentDirectory:(BOOL)keepParentDirectory
{
    return [SSZipArchive createZipFileAtPath:path withContentsOfDirectory:directoryPath keepParentDirectory:keepParentDirectory withPassword:nil];
}

+ (BOOL)createZipFileAtPath:(NSString *)path withFilesAtPaths:(NSArray*)paths withPassword:(NSString *)password
{
    SSZipArchive *zipArchive = [[SSZipArchive alloc] initWithPath:path];
    BOOL success = [zipArchive open];
    if (success)
    {
        for (NSString *filePath in paths)
            success &= [zipArchive writeFile:filePath withPassword:password];

        success &= [zipArchive close];
    }

    [zipArchive release];
    
    return success;
}

+ (BOOL)createZipFileAtPath:(NSString *)path
    withContentsOfDirectory:(NSString *)directoryPath
        keepParentDirectory:(BOOL)keepParentDirectory
           compressionLevel:(int)compressionLevel
                   password:(NSString *)password
                        AES:(BOOL)aes
{
    SSZipArchive *zipArchive = [[SSZipArchive alloc] initWithPath:path];
    BOOL success = [zipArchive open];
    if (success)
    {
        // use a local fileManager (queue/thread compatibility)
        NSFileManager *fileManager = NSFileManager.new;
        NSDirectoryEnumerator *dirEnumerator = [fileManager enumeratorAtPath:directoryPath];
        NSArray *allObjects = dirEnumerator.allObjects;
        NSUInteger total = allObjects.count;
        if (keepParentDirectory && total == 0)
            allObjects = [NSArray arrayWithObject:@""];
        
        for (NSString *fileName in allObjects)
        {
            NSString *fullFilePath = [directoryPath stringByAppendingPathComponent:fileName];
            
            if (keepParentDirectory)
                fileName = [directoryPath.lastPathComponent stringByAppendingPathComponent:fileName];
            
            BOOL isDir;
            [fileManager fileExistsAtPath:fullFilePath isDirectory:&isDir];
            if (!isDir)
            {
                // file
                success &= [zipArchive writeFileAtPath:fullFilePath withFileName:fileName compressionLevel:compressionLevel password:password AES:aes];
            }
            else
            {
                // directory
                if (![fileManager enumeratorAtPath:fullFilePath].nextObject)
                {
                    // empty directory
                    success &= [zipArchive writeFolderAtPath:fullFilePath withFolderName:fileName withPassword:password];
                }
            }
        }
        success &= zipArchive.close;
        
        [fileManager release];
    }
    
    [zipArchive release];
    return success;
}

+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath withPassword:(NSString *)password
{
    return [SSZipArchive createZipFileAtPath:path withContentsOfDirectory:directoryPath keepParentDirectory:NO withPassword:password];
}

+ (BOOL)createZipFileAtPath:(NSString *)path withContentsOfDirectory:(NSString *)directoryPath keepParentDirectory:(BOOL)keepParentDirectory withPassword:(NSString *)password
{
    return [SSZipArchive createZipFileAtPath:path
                     withContentsOfDirectory:directoryPath
                         keepParentDirectory:keepParentDirectory
                            compressionLevel:Z_DEFAULT_COMPRESSION
                                password:password
                                         AES:YES];
}


// disabling `init` because designated initializer is `initWithPath:`
- (SSZipArchive*)init { return nil; }

// designated initializer
- (SSZipArchive*)initWithPath:(NSString *)path
{
    self = super.init;
    
    _path = [path copy];
    
    return self;
}

- (void)dealloc
{
    [_path release];
    [super dealloc];
}

- (BOOL)open
{
    NSAssert((_zip == NULL), @"Attempting to open an archive which is already open");
    _zip = zipOpen(_path.fileSystemRepresentation, APPEND_STATUS_CREATE);
    return (NULL != _zip);
}

- (BOOL)writeFolderAtPath:(NSString *)path withFolderName:(NSString *)folderName withPassword:(NSString *)password
{
    NSAssert((_zip != NULL), @"Attempting to write to an archive which was never opened");
    
    zip_fileinfo zipInfo = {};
    
    [SSZipArchive zipInfo:&zipInfo setAttributesOfItemAtPath:path];
    
    int error = _zipOpenEntry(_zip, [folderName stringByAppendingString:@"/"], &zipInfo, Z_NO_COMPRESSION, password, 0);
    const void *buffer = NULL;
    zipWriteInFileInZip(_zip, buffer, 0);
    zipCloseFileInZip(_zip);
    return error == ZIP_OK;
}

- (BOOL)writeFile:(NSString *)path withPassword:(NSString *)password
{
    return [self writeFileAtPath:path withFileName:nil withPassword:password];
}

- (BOOL)writeFileAtPath:(NSString *)path withFileName:(NSString*)fileName withPassword:(NSString *)password
{
    return [self writeFileAtPath:path withFileName:fileName compressionLevel:Z_DEFAULT_COMPRESSION password:password AES:YES];
}

// supports writing files with logical folder/directory structure
// *path* is the absolute path of the file that will be compressed
// *fileName* is the relative name of the file how it is stored within the zip e.g. /folder/subfolder/text1.txt
- (BOOL)writeFileAtPath:(NSString *)path withFileName:(NSString *)fileName compressionLevel:(int)compressionLevel password:(NSString *)password AES:(BOOL)aes
{
    NSAssert((_zip != NULL), @"Attempting to write to an archive which was never opened");
    
    FILE *input = fopen(path.fileSystemRepresentation, "r");
    if (NULL == input)
        return NO;
    
    if (!fileName)
        fileName = path.lastPathComponent;
    
    zip_fileinfo zipInfo = {};
    
    [SSZipArchive zipInfo:&zipInfo setAttributesOfItemAtPath:path];
    
    void *buffer = malloc(CHUNK);
    if (buffer == NULL)
    {
        fclose(input);
        return NO;
    }
    
    int error = _zipOpenEntry(_zip, fileName, &zipInfo, compressionLevel, password, aes);
    
    while (feof(input) == 0 && ferror(input) == 0)
    {
        unsigned len = (unsigned)fread(buffer, 1, CHUNK, input);
        zipWriteInFileInZip(_zip, buffer, len);
    }
    
    zipCloseFileInZip(_zip);
    free(buffer);
    fclose(input);
    return error == ZIP_OK;
}

- (BOOL)writeData:(NSData *)data filename:(NSString *)filename withPassword:(NSString *)password
{
    return [self writeData:data filename:filename compressionLevel:Z_DEFAULT_COMPRESSION password:password AES:YES];
}

- (BOOL)writeData:(NSData *)data filename:(NSString *)filename compressionLevel:(int)compressionLevel password:(NSString *)password AES:(BOOL)aes
{
    if (_zip == nil)
        return NO;
    
    if (data == nil)
        return NO;

    zip_fileinfo zipInfo = {};
    [SSZipArchive zipInfo:&zipInfo setDate:[NSDate date]];
    
    int error = _zipOpenEntry(_zip, filename, &zipInfo, compressionLevel, password, aes);
    
    zipWriteInFileInZip(_zip, data.bytes, (unsigned)data.length);
    
    zipCloseFileInZip(_zip);
    return error == ZIP_OK;
}

- (BOOL)close
{
    NSAssert((_zip != NULL), @"[SSZipArchive] Attempting to close an archive which was never opened");
    int error = zipClose(_zip, NULL);
    _zip = nil;
    return error == ZIP_OK;
}

// MARK: Private

+ (NSString *)_filenameStringWithCString:(const char *)filename
                         version_made_by:(uint16_t)version_made_by
                    general_purpose_flag:(uint16_t)flag
                                    size:(uint16_t)size_filename {
    
    // Respect Language encoding flag only reading filename as UTF-8 when this is set
    // when file entry created on dos system.
    //
    // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
    //   Bit 11: Language encoding flag (EFS).  If this bit is set,
    //           the filename and comment fields for this file
    //           MUST be encoded using UTF-8. (see APPENDIX D)
    uint16_t made_by = version_made_by >> 8;
    BOOL made_on_dos = made_by == 0;
    BOOL languageEncoding = (flag & (1 << 11)) != 0;
    if (!languageEncoding && made_on_dos)
    {
        // APPNOTE.TXT D.1:
        //   D.2 If general purpose bit 11 is unset, the file name and comment should conform
        //   to the original ZIP character encoding.  If general purpose bit 11 is set, the
        //   filename and comment must support The Unicode Standard, Version 4.1.0 or
        //   greater using the character encoding form defined by the UTF-8 storage
        //   specification.  The Unicode Standard is published by the The Unicode
        //   Consortium (www.unicode.org).  UTF-8 encoded data stored within ZIP files
        //   is expected to not include a byte order mark (BOM).
        
        //  Code Page 437 corresponds to kCFStringEncodingDOSLatinUS
        NSString* strPath = [NSString stringWithCString:filename encoding:NSISOLatin1StringEncoding];
        if (strPath != nil)
            return strPath;
    }

    // attempting unicode encoding
    NSString * strPath = [NSString stringWithUTF8String:filename];
    if (strPath != nil)
        return strPath;
    
    // if filename is non-unicode, detect and transform Encoding
    NSData *data = [NSData dataWithBytes:(const void *)filename length:sizeof(char) * size_filename];

    const unsigned encodings[] = { NSJapaneseEUCStringEncoding, NSShiftJISStringEncoding, NSISO2022JPStringEncoding };
    const unsigned len = sizeof(encodings) / sizeof(encodings[0]);

    for (unsigned i = 0; i < len; i++)
    {
        strPath = [NSString stringWithCString:filename encoding:encodings[i]];
        if (strPath != nil)
            break;
    }

    if(strPath != nil)
        return strPath;
    
    // if filename encoding is non-detected, we default to something based on data
    // _hexString is more readable than _base64RFC4648 for debugging unknown encodings
    strPath = [data _hexString];
    return strPath;
}

+ (void)zipInfo:(zip_fileinfo *)zipInfo setAttributesOfItemAtPath:(NSString *)path
{
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error: nil];
    if (attr != nil)
    {
        NSDate *fileDate = (NSDate *)[attr objectForKey:NSFileModificationDate];
        if (fileDate != nil)
            [self zipInfo:zipInfo setDate:fileDate];
        
        // Write permissions into the external attributes, for details on this see here: http://unix.stackexchange.com/a/14727
        // Get the permissions value from the files attributes
        NSNumber *permissionsValue = (NSNumber *)[attr objectForKey:NSFilePosixPermissions];
        if (permissionsValue != nil)
        {
            // Get the short value for the permissions
            int permissionsShort = permissionsValue.shortValue;
            
            // Convert this into an octal by adding 010000, 010000 being the flag for a regular file
            NSInteger permissionsOctal = 0100000 + permissionsShort;
            
            // Convert this into a long value
            size_t permissionsLong = permissionsOctal;
            
            // Store this into the external file attributes once it has been shifted 16 places left to form part of the second from last byte
            
            // Casted back to an unsigned int to match type of external_fa in minizip
            zipInfo->external_fa = (unsigned)(permissionsLong << 16L);
        }
    }
}

+ (NSCalendar *)_gregorian
{
    return NSCalendar.currentCalendar;
}

+ (void)zipInfo:(zip_fileinfo *)zipInfo setDate:(NSDate *)date
{
    NSCalendar *currentCalendar = SSZipArchive._gregorian;
    NSCalendarUnit flags = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit | NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit;
    NSDateComponents *components = [currentCalendar components:flags fromDate:date];
    struct tm tmz_date;
    tmz_date.tm_sec = (unsigned)components.second;
    tmz_date.tm_min = (unsigned)components.minute;
    tmz_date.tm_hour = (unsigned)components.hour;
    tmz_date.tm_mday = (unsigned)components.day;
    // ISO/IEC 9899 struct tm is 0-indexed for January but NSDateComponents for gregorianCalendar is 1-indexed for January
    tmz_date.tm_mon = (unsigned)components.month - 1;
    // ISO/IEC 9899 struct tm is 0-indexed for AD 1900 but NSDateComponents for gregorianCalendar is 1-indexed for AD 1
    tmz_date.tm_year = (unsigned)components.year - 1900;
    zipInfo->dos_date = tm_to_dosdate(&tmz_date);
}

// Format from http://newsgroups.derkeiler.com/Archive/Comp/comp.os.msdos.programmer/2009-04/msg00060.html
// Two consecutive words, or a longword, YYYYYYYMMMMDDDDD hhhhhmmmmmmsssss
// YYYYYYY is years from 1980 = 0
// sssss is (seconds/2).
//
// 3658 = 0011 0110 0101 1000 = 0011011 0010 11000 = 27 2 24 = 2007-02-24
// 7423 = 0111 0100 0010 0011 - 01110 100001 00011 = 14 33 3 = 14:33:06
+ (NSDate *)_dateWithMSDOSFormat:(uint32_t)msdosDateTime
{
    // the whole `_dateWithMSDOSFormat:` method is equivalent but faster than this one line,
    // essentially because `mktime` is slow:
    //NSDate *date = [NSDate dateWithTimeIntervalSince1970:dosdate_to_time_t(msdosDateTime)];
    static const uint32_t kYearMask = 0xFE000000;
    static const uint32_t kMonthMask = 0x1E00000;
    static const uint32_t kDayMask = 0x1F0000;
    static const uint32_t kHourMask = 0xF800;
    static const uint32_t kMinuteMask = 0x7E0;
    static const uint32_t kSecondMask = 0x1F;
    
    NSAssert(0xFFFFFFFF == (kYearMask | kMonthMask | kDayMask | kHourMask | kMinuteMask | kSecondMask), @"[SSZipArchive] MSDOS date masks don't add up");
    
    NSDateComponents *components = NSDateComponents.new;
    components.year = 1980 + ((msdosDateTime & kYearMask) >> 25);
    components.month = (msdosDateTime & kMonthMask) >> 21;
    components.day = (msdosDateTime & kDayMask) >> 16;
    components.hour = (msdosDateTime & kHourMask) >> 11;
    components.minute = (msdosDateTime & kMinuteMask) >> 5;
    components.second = (msdosDateTime & kSecondMask) * 2;
    
    NSDate *date = [self._gregorian dateFromComponents:components];
    [components release];
    return date;
}

@end

int _zipOpenEntry(zipFile entry, NSString *name, const zip_fileinfo *zipfi, int level, NSString *password, BOOL aes)
{
    return zipOpenNewFileInZip5(entry, name.fileSystemRepresentation, zipfi, NULL, 0, NULL, 0, NULL, 0, 0, Z_DEFLATED, level, 0, -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY, password.UTF8String, aes, 0);
}

// MARK: Private tools for file info

BOOL _fileIsSymbolicLink(const unz_file_info *fileInfo)
{
    //
    // Determine whether this is a symbolic link:
    // - File is stored with 'version made by' value of UNIX (3),
    //   as per http://www.pkware.com/documents/casestudies/APPNOTE.TXT
    //   in the upper byte of the version field.
    // - BSD4.4 st_mode constants are stored in the high 16 bits of the
    //   external file attributes (defacto standard, verified against libarchive)
    //
    // The original constants can be found here:
    //    http://minnie.tuhs.org/cgi-bin/utree.pl?file=4.4BSD/usr/include/sys/stat.h
    //
    const size_t ZipUNIXVersion = 3;
    const size_t BSD_SFMT = 0170000;
    const size_t BSD_IFLNK = 0120000;
    
    BOOL fileIsSymbolicLink = ((fileInfo->version >> 8) == ZipUNIXVersion) && BSD_IFLNK == (BSD_SFMT & (fileInfo->external_fa >> 16));
    return fileIsSymbolicLink;
}

// MARK: Private tools for unreadable encodings

@implementation NSData (SSZipArchive)

// initWithBytesNoCopy from NSProgrammer, Jan 25 '12: https://stackoverflow.com/a/9009321/1033581
// hexChars from Peter, Aug 19 '14: https://stackoverflow.com/a/25378464/1033581
// not implemented as too lengthy: a potential mapping improvement from Moose, Nov 3 '15: https://stackoverflow.com/a/33501154/1033581
- (NSString *)_hexString
{
    const char *hexChars = "0123456789ABCDEF";
    NSUInteger length = self.length;
    const uint8_t *bytes = self.bytes;
    char *chars = malloc(length * 2);
    if (chars == NULL)        
        return nil;
    
    char *s = chars;
    NSUInteger i = length;
    while (i--)
    {
        *s++ = hexChars[*bytes >> 4];
        *s++ = hexChars[*bytes & 0xF];
        bytes++;
    }
    
    NSString *str = [[NSString alloc] initWithBytesNoCopy:chars
                                                   length:length * 2
                                                 encoding:NSASCIIStringEncoding
                                             freeWhenDone:YES];
    return str.autorelease;
}

@end

// MARK: Private tools for security

@implementation NSString (SSZipArchive)

// One implementation alternative would be to use the algorithm found at mz_path_resolve from https://github.com/nmoinvaz/minizip/blob/dev/mz_os.c,
// but making sure to work with unichar values and not ascii values to avoid breaking Unicode characters containing 2E ('.') or 2F ('/') in their decomposition
/// Sanitize path traversal characters to prevent directory backtracking. Ignoring these characters mimicks the default behavior of the Unarchiving tool on macOS.
- (NSString *)_sanitizedPath
{
    // Change Windows paths to Unix paths: https://en.wikipedia.org/wiki/Path_(computing)
    // Possible improvement: only do this if the archive was created on a non-Unix system
    NSString *strPath = [self stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    // Percent-encode file path (where path is defined by https://tools.ietf.org/html/rfc8089)
    // The key part is to allow characters "." and "/" and disallow "%".
    // CharacterSet.urlPathAllowed seems to do the job
    // Testing availability of @available (https://stackoverflow.com/a/46927445/1033581)

    strPath = [strPath stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    // `NSString.stringByAddingPercentEncodingWithAllowedCharacters:` may theorically fail: https://stackoverflow.com/questions/33558933/
    // But because we auto-detect encoding using `NSString.stringEncodingForData:encodingOptions:convertedString:usedLossyConversion:`,
    // we likely already prevent UTF-16, UTF-32 and invalid Unicode in the form of unpaired surrogate chars: https://stackoverflow.com/questions/53043876/
    // To be on the safe side, we will still perform a guard check.
    if (strPath == nil)
        return nil;
    
    // Add scheme "file:///" to support sanitation on names with a colon like "file:a/../../../usr/bin"
    strPath = [@"file:///" stringByAppendingString:strPath];
    
    // Sanitize path traversal characters to prevent directory backtracking. Ignoring these characters mimicks the default behavior of the Unarchiving tool on macOS.
    // "../../../../../../../../../../../tmp/test.txt" -> "tmp/test.txt"
    // "a/b/../c.txt" -> "a/c.txt"
    NSURL *url = [NSURL URLWithString:strPath];
    strPath = url.standardizedURL.absoluteString;
    
    // Remove the "file:///" scheme
    strPath = [strPath substringFromIndex:8];
    
    // Remove the percent-encoding
    // Testing availability of @available (https://stackoverflow.com/a/46927445/1033581)
    strPath = [strPath stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    return strPath;
}

@end

