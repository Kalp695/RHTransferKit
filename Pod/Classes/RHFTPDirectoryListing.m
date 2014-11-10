//
//  RHFTPDirectoryListing.m
//  iCED
//
//  Created by Ryan on 2010-08-16.
//  Copyright 2010 Murage Inc. All rights reserved.
//

#import "RHFTPDirectoryListing.h"

#include <sys/socket.h>
#include <sys/dirent.h>

#include <CFNetwork/CFNetwork.h>

#pragma mark * ListController

@interface RHFTPDirectoryListing()
@property(nonatomic,readonly) BOOL isReceiving;
@property(nonatomic,retain) NSInputStream *networkStream;
@property(nonatomic,retain) NSMutableData *listData;
@property(nonatomic,copy) NSString *status;
@property(nonatomic,retain) NSURL *url;
- (void)_updateStatus:(NSString *)statusString;
- (void)closeConnection;
@end

@implementation RHFTPDirectoryListing

@synthesize networkStream   = _networkStream;
@synthesize listData        = _listData;
@synthesize listEntries     = _listEntries;
@synthesize status          = _status;
@synthesize url;
@synthesize delegate;

- (id)initWithFtpUrl:(NSURL *)theUrl {
	self = [super init];
	if (self != nil) {
		url = [theUrl retain];
		
		if (self.listEntries == nil) {
			_listEntries = [[NSMutableDictionary alloc] init];
			assert(self.listEntries != nil);
		}		
	}
	return self;
}

- (void) dealloc {
	NSLog(@"Deallocating %@", self);
	[self closeConnection];
	delegate = nil;
	[url release];
	[_listData release];
	[super dealloc];
}

#pragma mark -
#pragma mark Private

- (void)closeConnection {
    if (self.networkStream != nil) {
		CFRunLoopStop([[NSRunLoop currentRunLoop] getCFRunLoop]);
        self.networkStream.delegate = nil;
        [self.networkStream close];
        [self.networkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.networkStream = nil;
    }
}

#pragma mark * Status management

// These methods are used by the core transfer code to update the UI.

- (void)_receiveDidStart
{
    // Clear the current image so that we get a nice visual cue if the receive fails.
    [self.listEntries removeAllObjects];
    [self _updateStatus:@"Receiving"];
    //[[AppDelegate sharedAppDelegate] didStartNetworking];
}

- (void)_updateStatus:(NSString *)statusString
{
    assert(statusString != nil);
	NSLog(@"%@", statusString);
}

- (void)_addListEntries:(NSDictionary *)newEntries
{
    assert(self.listEntries != nil);
    
    [self.listEntries addEntriesFromDictionary:newEntries];
}

- (void)_receiveDidStopWithStatus:(NSString *)statusString
{
	[self retain]; // in case delegate responding to directoryListingAvailable: releases this instance
    if (statusString == nil) {
        statusString = @"List succeeded";
		
		if ([delegate respondsToSelector:@selector(directoryListingAvailable:)]) {
			[delegate directoryListingAvailable:self];
		}
    }
    [self _updateStatus:statusString];
	[self release];
}

#pragma mark * Core transfer code

// This is the code that actually does the networking.

- (BOOL)isReceiving
{
    return (self.networkStream != nil);
}

- (void)startReceive
    // Starts a connection to download the current URL.
{	
    //BOOL                success;
    CFReadStreamRef     ftpStream;
    
    assert(self.networkStream == nil);      // don't tap receive twice in a row!

    // First get and check the URL.
    
    //url = [[AppDelegate sharedAppDelegate] smartURLForString:self.urlText.text];
    //success = (url != nil);

    // If the URL is bogus, let the user know.  Otherwise kick off the connection.
    
	
	// Create the mutable data into which we will receive the listing.
	self.listData = [NSMutableData data];
	assert(self.listData != nil);
	
	// Open a CFFTPStream for the URL.
	ftpStream = CFReadStreamCreateWithFTPURL(NULL, (CFURLRef) url);
	assert(ftpStream != NULL);
	self.networkStream = (NSInputStream *) ftpStream;
	self.networkStream.delegate = self;
	[self.networkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	
	CFReadStreamSetProperty(ftpStream, kCFStreamPropertyFTPFetchResourceInfo, kCFBooleanFalse);
	CFReadStreamSetProperty(ftpStream, kCFStreamPropertyFTPAttemptPersistentConnection, kCFBooleanFalse);
	CFReadStreamSetProperty(ftpStream, kCFStreamPropertyFTPUsePassiveMode, kCFBooleanTrue);	
	[self.networkStream open];
	
	// Have to release ftpStream to balance out the create.  self.networkStream 
	// has retained this for our persistent use.
	CFRelease(ftpStream);
	
	// Tell the UI we're receiving.
	[self _receiveDidStart];
	
	CFRunLoopRun();
}

//- (void)startReceive {
//	[self performSelectorInBackground:@selector(_startReceive) withObject:nil];
//}

- (void)_stopReceiveWithStatus:(NSString *)statusString
    // Shuts down the connection and displays the result (statusString == nil) 
    // or the error status (otherwise).
{
	[self closeConnection];
    [self _receiveDidStopWithStatus:statusString];
    self.listData = nil;
}

- (NSDictionary *)_entryByReencodingNameInEntry:(NSDictionary *)entry encoding:(NSStringEncoding)newEncoding
    // CFFTPCreateParsedResourceListing always interprets the file name as MacRoman, 
    // which is clearly bogus <rdar://problem/7420589>.  This code attempts to fix 
    // that by converting the Unicode name back to MacRoman (to get the original bytes; 
    // this works because there's a lossless round trip between MacRoman and Unicode) 
    // and then reconverting those bytes to Unicode using the encoding provided. 
{
    NSDictionary *  result;
    NSString *      name;
    NSData *        nameData;
    NSString *      newName;
    
    newName = nil;
    
    // Try to get the name, convert it back to MacRoman, and then reconvert it 
    // with the preferred encoding.
    
    name = [entry objectForKey:(id) kCFFTPResourceName];
    if (name != nil) {
        assert([name isKindOfClass:[NSString class]]);
        
        nameData = [name dataUsingEncoding:NSMacOSRomanStringEncoding];
        if (nameData != nil) {
            newName = [[[NSString alloc] initWithData:nameData encoding:newEncoding] autorelease];
        }
    }
    
    // If the above failed, just return the entry unmodified.  If it succeeded, 
    // make a copy of the entry and replace the name with the new name that we 
    // calculated.
    
    if (newName == nil) {
        assert(NO);                 // in the debug builds, if this fails, we should investigate why
        result = (NSDictionary *) entry;
    } else {
        NSMutableDictionary *   newEntry;
        
        newEntry = [[entry mutableCopy] autorelease];
        assert(newEntry != nil);
        
        [newEntry setObject:newName forKey:(id) kCFFTPResourceName];
        
        result = newEntry;
    }
    
    return result;
}

- (void)_parseListData
{
    NSMutableDictionary *newEntries;
    NSUInteger          offset;
    
    // We accumulate the new entries into an array to avoid a) adding items to the 
    // table one-by-one, and b) repeatedly shuffling the listData buffer around.
    
    newEntries = [NSMutableDictionary dictionary];
    assert(newEntries != nil);
    
    offset = 0;
    do {
        CFIndex         bytesConsumed;
        CFDictionaryRef thisEntry;
        
        thisEntry = NULL;
        
        assert(offset <= self.listData.length);
        bytesConsumed = CFFTPCreateParsedResourceListing(NULL, &((const uint8_t *) self.listData.bytes)[offset], self.listData.length - offset, &thisEntry);
        if (bytesConsumed > 0) {

            // It is possible for CFFTPCreateParsedResourceListing to return a 
            // positive number but not create a parse dictionary.  For example, 
            // if the end of the listing text contains stuff that can't be parsed, 
            // CFFTPCreateParsedResourceListing returns a positive number (to tell 
            // the caller that it has consumed the data), but doesn't create a parse 
            // dictionary (because it couldn't make sense of the data).  So, it's 
            // important that we check for NULL.

            if (thisEntry != NULL) {
                NSDictionary *  entryToAdd;
                
                // Try to interpret the name as UTF-8, which makes things work properly 
                // with many UNIX-like systems, including the Mac OS X built-in FTP 
                // server.  If you have some idea what type of text your target system 
                // is going to return, you could tweak this encoding.  For example, 
                // if you know that the target system is running Windows, then 
                // NSWindowsCP1252StringEncoding would be a good choice here.
                // 
                // Alternatively you could let the user choose the encoding up 
                // front, or reencode the listing after they've seen it and decided 
                // it's wrong.
                //
                // Ain't FTP a wonderful protocol!

                entryToAdd = [self _entryByReencodingNameInEntry:(NSDictionary *)thisEntry encoding:NSUTF8StringEncoding];
                [newEntries setObject:entryToAdd forKey:(NSString *)[(NSDictionary *)thisEntry objectForKey:(id)kCFFTPResourceName]];
            }
            
            // We consume the bytes regardless of whether we get an entry.
            
            offset += bytesConsumed;
        }
        
        if (thisEntry != NULL) {
            CFRelease(thisEntry);
        }
        
        if (bytesConsumed == 0) {
            // We haven't yet got enough data to parse an entry.  Wait for more data 
            // to arrive.
            break;
        } else if (bytesConsumed < 0) {
            // We totally failed to parse the listing.  Fail.
            [self _stopReceiveWithStatus:@"Listing parse failed"];
            break;
        }
    } while (YES);

    if (newEntries.count != 0) {
        [self _addListEntries:newEntries];
    }
    if (offset != 0) {
        [self.listData replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode
    // An NSStream delegate callback that's called when events happen on our 
    // network stream.
{
    assert(stream == self.networkStream);

    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            [self _updateStatus:@"Opened connection"];
			break;
        }
        case NSStreamEventHasBytesAvailable: {
            NSInteger       bytesRead;
            uint8_t         buffer[32768];

            [self _updateStatus:@"Receiving"];
            
            // Pull some data off the network.
            bytesRead = [self.networkStream read:buffer maxLength:sizeof(buffer)];
            if (bytesRead == -1) {
                [self _stopReceiveWithStatus:@"Network read error"];
            } else if (bytesRead == 0) {
                [self _stopReceiveWithStatus:nil];
            } else {
                assert(self.listData != nil);
                
                // Append the data to our listing buffer.
                [self.listData appendBytes:buffer length:bytesRead];
                
                // Check the listing buffer for any complete entries and update 
                // the UI if we find any.
                [self _parseListData];
            }
			break;
        }
        case NSStreamEventHasSpaceAvailable: {
            assert(NO);     // should never happen for the output stream
			break;
        }
        case NSStreamEventErrorOccurred: {
			NSError *error = [stream streamError];
			NSLog(@"URL: %@", self.url);
			NSLog(@"NSStreamEventErrorOccurred: %@", [error localizedDescription]);
			if ([delegate respondsToSelector:@selector(directoryListingDidFailToEstablishConnection:withError:)]) {
				[delegate directoryListingDidFailToEstablishConnection:self withError:error];
			}
			break;
        }
        case NSStreamEventEndEncountered: {
            // ignore
			break;
        }
        default: {
            assert(NO);
			break;
        }
    }
}

#pragma mark * Table view data source and delegate

- (NSString *)_stringForNumber:(double)num asUnits:(NSString *)units
{
    NSString *  result;
    double      fractional;
    double      integral;
    
    fractional = modf(num, &integral);
    if ( (fractional < 0.1) || (fractional > 0.9) ) {
        result = [NSString stringWithFormat:@"%.0f %@", round(num), units];
    } else {
        result = [NSString stringWithFormat:@"%.1f %@", num, units];
    }
    return result;
}

- (NSString *)_stringForFileSize:(unsigned long long)fileSizeExact
{
    double  fileSize;
    NSString *  result;
    
    fileSize = (double) fileSizeExact;
    if (fileSizeExact == 1) {
        result = @"1 byte";
    } else if (fileSizeExact < 1024) {
        result = [NSString stringWithFormat:@"%llu bytes", fileSizeExact];
    } else if (fileSize < (1024.0 * 1024.0 * 0.1)) {
        result = [self _stringForNumber:fileSize / 1024.0 asUnits:@"KB"];
    } else if (fileSize < (1024.0 * 1024.0 * 1024.0 * 0.1)) {
        result = [self _stringForNumber:fileSize / (1024.0 * 1024.0) asUnits:@"MB"];
    } else {
        result = [self _stringForNumber:fileSize / (1024.0 * 1024.0 * 1024.0) asUnits:@"MB"];
    }
    return result;
}

@end