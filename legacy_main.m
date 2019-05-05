#import <Foundation/Foundation.h>
#import "ZipArchive/ZennyZipArchive.h"


int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = NSAutoreleasePool.new;
    
    NSString *htmlPath = [NSBundle.mainBundle pathForResource:@"index" ofType:@"html" inDirectory:@"html/device"];
    NSString *jsPath = [NSBundle.mainBundle pathForResource:@"device" ofType:@"js" inDirectory:@"html/device"];
    
    // 测试压缩
    ZennyZipArchive *zipfile = ZennyZipArchive.new;
    NSString *path = [NSTemporaryDirectory() stringByAppendingString:@"test.zip"];
    
    if(![zipfile CreateZipFile2:path])
        NSLog(@"Failed to create zip file!");
    else
    {
        [zipfile addFileToZip:htmlPath newname:@"index.html"];
        [zipfile addFileToZip:jsPath newname:@"device.js"];
    }

    [zipfile CloseZipFile2];
    [zipfile release];
    
    // 测试解压
    zipfile = ZennyZipArchive.new;
    NSString *dstPath = [NSTemporaryDirectory() stringByAppendingString:@"test"];
    if(![zipfile UnzipOpenFile:path])
        NSLog(@"Failed to open the zip file!");
    else
        [zipfile UnzipFileTo:dstPath overWrite:YES];
    
    [zipfile UnzipCloseFile];
    [zipfile release];
    
    [pool drain];
}

