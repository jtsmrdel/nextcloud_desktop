/*
 * Copyright (C) 2023 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include "fileproviderxpc_mac_utils.h"

#include <QLoggingCategory>

#include "gui/accountmanager.h"

#import "ClientCommunicationProtocol.h"

namespace {

static const char *const clientCommunicationServiceName = "com.nextcloud.desktopclient.ClientCommunicationService";
static NSString *const nsClientCommunicationServiceName = [NSString stringWithUTF8String:clientCommunicationServiceName];

}

namespace OCC {

namespace Mac {

Q_LOGGING_CATEGORY(lcFileProviderXPCUtils, "nextcloud.gui.macos.fileprovider.xpc.utils", QtInfoMsg)

namespace FileProviderXPCUtils {

NSArray<NSFileProviderManager *> *getDomainManagers()
{
    dispatch_group_t group = dispatch_group_create();
    __block NSMutableArray<NSFileProviderManager *> *managers = NSMutableArray.array;

    dispatch_group_enter(group);

    // Set up connections for each domain
    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *const domains, NSError *const error){
        if (error != nil) {
            qCWarning(lcFileProviderXPCUtils) << "Error getting domains" << error;
            dispatch_group_leave(group);
            return;
        }

        for (NSFileProviderDomain *const domain in domains) {
            qCInfo(lcFileProviderXPCUtils) << "Got domain" << domain.identifier;
            NSFileProviderManager *const manager = [NSFileProviderManager managerForDomain:domain];
            [managers addObject:manager];
        }

        dispatch_group_leave(group);
    }];

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (managers.count == 0) {
        qCWarning(lcFileProviderXPCUtils) << "No domains found";
    }

    return managers.copy;
}

NSArray<NSURL *> *getDomainUrlsForManagers(NSArray<NSFileProviderManager *> *managers)
{
    dispatch_group_t group = dispatch_group_create();
    __block NSMutableArray<NSURL *> *urls = NSMutableArray.array;

    for (NSFileProviderManager *const manager in managers) {

        dispatch_group_enter(group);

        [manager getUserVisibleURLForItemIdentifier:NSFileProviderRootContainerItemIdentifier
                                  completionHandler:^(NSURL *const url, NSError *const error){
            if (error != nil) {
                qCWarning(lcFileProviderXPCUtils) << "Error getting user visible url" << error;
                dispatch_group_leave(group);
                return;
            }

            qCDebug(lcFileProviderXPCUtils) << "Got user visible url" << url;
            [urls addObject:url];
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (urls.count == 0) {
        qCWarning(lcFileProviderXPCUtils) << "No urls found";
    }

    return urls.copy;
}

NSArray<NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *> *getFileProviderServicesAtUrls(NSArray<NSURL *> *urls)
{
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *> *const fpServices = NSMutableArray.array;

    for (NSURL *const url in urls) {
        dispatch_group_enter(group);

        [NSFileManager.defaultManager getFileProviderServicesForItemAtURL:url
                                                        completionHandler:^(NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *const services, NSError *const error){
            if (error != nil) {
                qCWarning(lcFileProviderXPCUtils) << "Error getting file provider services" << error;
                dispatch_group_leave(group);
                return;
            }

            qCInfo(lcFileProviderXPCUtils) << "Got file provider services for"
                                      << url.absoluteString
                                      << "has number of services:"
                                      << services.count;
            [fpServices addObject:services];
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (fpServices.count == 0) {
        qCWarning(lcFileProviderXPCUtils) << "No file provider services found";
    }

    return fpServices.copy;
}

NSArray<NSXPCConnection *> *connectToFileProviderServices(NSArray<NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *> *fpServices)
{
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSXPCConnection *> *const connections = NSMutableArray.array;

    for (NSDictionary<NSFileProviderServiceName, NSFileProviderService *> *const services in fpServices) {
        NSArray<NSFileProviderServiceName> *const serviceNamesArray = services.allKeys;

        for (NSFileProviderServiceName serviceName in serviceNamesArray) {
            qCInfo(lcFileProviderXPCUtils) << "Got service" << serviceName;

            if (![serviceName isEqualToString:nsClientCommunicationServiceName]) {
                continue;
            }

            NSFileProviderService *const service = services[serviceName];
            dispatch_group_enter(group);

            [service getFileProviderConnectionWithCompletionHandler:^(NSXPCConnection *const connection, NSError *const error){
                if (error != nil) {
                    qCWarning(lcFileProviderXPCUtils) << "Error getting file provider connection" << error;
                    dispatch_group_leave(group);
                    return;
                }

                qCInfo(lcFileProviderXPCUtils) << "Got file provider connection" << connection;

                if (connection == nil) {
                    qCWarning(lcFileProviderXPCUtils) << "Connection is nil";
                    dispatch_group_leave(group);
                    return;
                }

                [connection retain];
                [connections addObject:connection];
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return connections.copy;
}

void configureFileProviderConnection(NSXPCConnection *const connection)
{
    Q_ASSERT(connection != nil);
    connection.interruptionHandler = ^{
        qCInfo(lcFileProviderXPCUtils) << "File provider connection interrupted";
    };
    connection.invalidationHandler = ^{
        qCInfo(lcFileProviderXPCUtils) << "File provider connection invalidated";
    };
    [connection resume];
}

NSObject *getRemoteServiceObject(NSXPCConnection *const connection, Protocol *const protocol)
{
    Q_ASSERT(connection != nil);
    Q_ASSERT(protocol != nil);
    const id remoteServiceObject = [connection remoteObjectProxyWithErrorHandler:^(NSError *const error){
        qCWarning(lcFileProviderXPCUtils) << "Error getting remote object proxy" << error;
    }];
    if (remoteServiceObject == nil) {
        return nil;
    }
    if (![remoteServiceObject conformsToProtocol:@protocol(ClientCommunicationProtocol)]) {
        qCWarning(lcFileProviderXPCUtils) << "Remote service object does not conform to protocol";
        return nil;
    }
    return remoteServiceObject;
}

}

}

} // namespace FileProviderXPCUtils

} // namespace Mac

} // namespace OCC
