/*
 *  MaplyQuadImageOfflineLayer.mm
 *  WhirlyGlobe-MaplyComponent
 *
 *  Created by Steve Gifford on 10/7/13.
 *  Copyright 2011-2013 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "MaplyQuadImageOfflineLayer.h"
#import "MaplyCoordinateSystem_private.h"
#import "MaplyViewControllerLayer_private.h"
#import "QuadDisplayLayer.h"
#import "MaplyActiveObject.h"
#import "MaplyActiveObject_private.h"
#import "WhirlyGlobe.h"

using namespace WhirlyKit;

@interface MaplyQuadImageOfflineLayer() <WhirlyKitQuadDataStructure,WhirlyKitQuadTileImageDataSource,WhirlyKitQuadTileOfflineDelegate>
@end

@implementation MaplyQuadImageOfflineLayer
{
    MaplyBaseViewController * __weak _viewC;
    MaplyCoordinateSystem *coordSys;
    WhirlyKitQuadTileOfflineLoader *tileLoader;
    WhirlyKitQuadDisplayLayer *quadLayer;
    NSObject<MaplyTileSource> *tileSource;
    Scene *scene;
    bool sourceSupportsMulti;
    int minZoom,maxZoom;
    int tileSize;
}

- (id)initWithCoordSystem:(MaplyCoordinateSystem *)inCoordSys tileSource:(NSObject<MaplyTileSource> *)inTileSource
{
    self = [super init];
    
    coordSys = inCoordSys;
    tileSource = inTileSource;
    _maxTiles = 256;
    _numSimultaneousFetches = 8;
    _flipY = true;
    _imageDepth = 1;
    _asyncFetching = true;
    _period = 0.0;
    _bbox.ll = MaplyCoordinateMakeWithDegrees(-180, -90);
    _bbox.ur = MaplyCoordinateMakeWithDegrees(+180, +90);
    
    // Check if the source can handle multiple images
    sourceSupportsMulti = [tileSource respondsToSelector:@selector(imagesForTile:numImages:)];
    
    return self;
}

- (void)setBbox:(MaplyBoundingBox)bbox
{
    _bbox = bbox;
    Mbr mbr(Point2f(bbox.ll.x,bbox.ll.y),Point2f(bbox.ur.x,bbox.ur.y));
    tileLoader.mbr = mbr;
}

- (void)reload
{
    if ([NSThread currentThread] != super.layerThread)
    {
        [self performSelector:@selector(reload) onThread:super.layerThread withObject:nil waitUntilDone:NO];
        return;
    }
    
    [quadLayer refresh];
}

- (void)cleanupLayers:(WhirlyKitLayerThread *)inLayerThread scene:(WhirlyKit::Scene *)scene
{
    [inLayerThread removeLayer:quadLayer];
}

#pragma mark - WhirlyKitQuadDataStructure,WhirlyKitQuadTileImageDataSource

- (bool)startLayer:(WhirlyKitLayerThread *)inLayerThread scene:(WhirlyKit::Scene *)inScene renderer:(WhirlyKitSceneRendererES *)renderer viewC:(MaplyBaseViewController *)viewC
{
    _viewC = viewC;
    super.layerThread = inLayerThread;
    scene = inScene;
    
    minZoom = [tileSource minZoom];
    maxZoom = [tileSource maxZoom];
    tileSize = [tileSource tileSize];

    // Set up tile and and quad layer with us as the data source
    tileLoader = [[WhirlyKitQuadTileOfflineLoader alloc] initWithName:@"Offline" dataSource:self];
    tileLoader.outputDelegate = self;
    tileLoader.period = _period;
    Mbr mbr = Mbr(Point2f(_bbox.ll.x,_bbox.ll.y),Point2f(_bbox.ur.x,_bbox.ur.y));
    tileLoader.mbr = mbr;
    tileLoader.outputDelegate = self;
    tileLoader.numImages = _imageDepth;
    
    quadLayer = [[WhirlyKitQuadDisplayLayer alloc] initWithDataSource:self loader:tileLoader renderer:renderer];
    quadLayer.maxTiles = _maxTiles;
    
    [super.layerThread addLayer:quadLayer];
    
    return true;
}

/// Return the coordinate system we're working in
- (WhirlyKit::CoordSystem *)coordSystem
{
    return [coordSys getCoordSystem];
}

/// Bounding box used to calculate quad tree nodes.  In local coordinate system.
- (WhirlyKit::Mbr)totalExtents
{
    MaplyCoordinate ll,ur;
    [coordSys getBoundsLL:&ll ur:&ur];
    
    Mbr mbr(Point2f(ll.x,ll.y),Point2f(ur.x,ur.y));
    return mbr;
}

/// Bounding box of data you actually want to display.  In local coordinate system.
/// Unless you're being clever, make this the same as totalExtents.
- (WhirlyKit::Mbr)validExtents
{
    return [self totalExtents];
}

/// Return the minimum quad tree zoom level (usually 0)
- (int)minZoom
{
    return minZoom;
}

/// Return the maximum quad tree zoom level.  Must be at least minZoom
- (int)maxZoom
{
    return maxZoom;
}

/// Return an importance value for the given tile
- (double)importanceForTile:(WhirlyKit::Quadtree::Identifier)ident mbr:(WhirlyKit::Mbr)mbr viewInfo:(WhirlyKitViewState *) viewState frameSize:(WhirlyKit::Point2f)frameSize attrs:(NSMutableDictionary *)attrs
{
    if (ident.level == 0)
        return MAXFLOAT;
    
    double import = 0.0;
    import = ScreenImportance(viewState, frameSize, viewState.eyeVec, tileSize, [coordSys getCoordSystem], scene->getCoordAdapter(), mbr, ident, attrs);
    
    //    NSLog(@"Tiles = %d: (%d,%d), import = %f",ident.level,ident.x,ident.y,import);
    
    return import;
}

- (void)quadTileLoader:(WhirlyKitQuadTileLoader *)quadLoader startFetchForLevel:(int)level col:(int)col row:(int)row attrs:(NSMutableDictionary *)attrs
{
    MaplyTileID tileID;
    tileID.x = col;  tileID.y = row;  tileID.level = level;
    
    // If we're not going OSM style addressing, we need to flip the Y back to TMS
    if (!_flipY)
    {
        int y = (1<<level)-tileID.y-1;
        tileID.y = y;
    }
    
    // This is the fetching block.  We'll invoke it a couple of different ways below.
    void (^workBlock)() =
    ^{
        NSMutableArray *imageDataArr = [NSMutableArray array];
        
        // Fetch the images
        if (sourceSupportsMulti)
            imageDataArr = [NSMutableArray arrayWithArray:[tileSource imagesForTile:tileID numImages:_imageDepth]];
        else {
            NSData *imgData = [tileSource imageForTile:tileID];
            if (imgData)
                [(NSMutableArray *)imageDataArr addObject:imgData];
        }
        
#ifdef TRASHTEST
        // Mess with some of the images to test corruption
        if (tileID.level > 1)
        {
            for (unsigned int ii=0;ii<_imageDepth;ii++)
            {
                NSObject *imgData = [imageDataArr objectAtIndex:ii];
                // Every so often let's return garbage
                if (imgData && (int)(drand48()*5) == 4)
                {
                    unsigned char *trash = (unsigned char *) malloc(2048);
                    for (unsigned int ii=0;ii<2048;ii++)
                        trash[ii] = drand48()*255;
                    imgData = [[NSData alloc] initWithBytesNoCopy:trash length:2048 freeWhenDone:YES];
                }
                [imageDataArr replaceObjectAtIndex:ii withObject:imgData];
            }
        }
#endif
        
        WhirlyKitLoadedTile *loadTile = [[WhirlyKitLoadedTile alloc] init];
        if ([imageDataArr count] == _imageDepth)
        {
            for (unsigned int ii=0;ii<_imageDepth;ii++)
            {
                WhirlyKitLoadedImage *loadImage = nil;
                NSObject *imgData = [imageDataArr objectAtIndex:ii];
                if ([imgData isKindOfClass:[UIImage class]])
                {
                    loadImage = [WhirlyKitLoadedImage LoadedImageWithUIImage:(UIImage *)imgData];
                } else if ([imgData isKindOfClass:[NSData class]])
                {
                    loadImage = [WhirlyKitLoadedImage LoadedImageWithNSDataAsPNGorJPG:(NSData *)imgData];
                }
                if (!loadImage)
                    break;
                [loadTile.images addObject:loadImage];
            }
        } else
            loadTile = nil;
        
        NSArray *args = @[(loadTile ? loadTile : [NSNull null]),@(col),@(row),@(level)];
        if (super.layerThread)
        {
            if ([NSThread currentThread] == super.layerThread)
                [self performSelector:@selector(mergeTile:) withObject:args];
            else
                [self performSelector:@selector(mergeTile:) onThread:super.layerThread withObject:args waitUntilDone:NO];
        }
    };
    
    // For async mode, off we go
    if (_asyncFetching)
    {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                       workBlock);
    } else {
        // In sync mode, we just do the work
        workBlock();
    }
}

// Merge the tile result back on the layer thread
- (void)mergeTile:(NSArray *)args
{
    if (!super.layerThread)
        return;
    
    WhirlyKitLoadedTile *loadTile = args[0];
    if ([loadTile isKindOfClass:[NSNull class]])
        loadTile = nil;
    int col = [args[1] intValue];
    int row = [args[2] intValue];
    int level = [args[3] intValue];
    
    [tileLoader dataSource: self loadedImage:loadTile forLevel: level col: col row: row];
}

/// Called when the layer is shutting down.  Clean up any drawable data and clear out caches.
- (void)shutdown
{
    super.layerThread = nil;
}

// Note: Should allow the users to set this
- (int)maxSimultaneousFetches
{
    return _numSimultaneousFetches;
}

#pragma mark - WhirlyKitQuadTileOfflineDelegate

// Here's where we get the generated image back.
// We're not on the main thread, Dorothy.
- (void)loader:(WhirlyKitQuadTileOfflineLoader *)loader image:(NSArray *)images mbr:(Mbr)mbr
{
    if (_delegate && images && [images count])
    {
        MaplyBoundingBox bbox;
        bbox.ll.x = mbr.ll().x();  bbox.ll.y = mbr.ll().y();
        bbox.ur.x = mbr.ur().x();  bbox.ur.y = mbr.ur().y();
        [_delegate offlineLayer:self images:images bbox:bbox];
    }
}


@end
