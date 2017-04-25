module Simula.NewCompositor.SceneGraph where

import Control.Lens
import Control.Monad
import Control.Monad.Loops
import Data.IORef
import Data.Typeable
import Linear
import Linear.OpenGL

import Graphics.Rendering.OpenGL.GL hiding (normalize)
import Foreign

import Simula.WaylandServer

import {-# SOURCE #-} Simula.NewCompositor.Compositor
import Simula.NewCompositor.Geometry
import Simula.NewCompositor.OpenGL
import {-# SOURCE #-} Simula.NewCompositor.WindowManager
import Simula.NewCompositor.Types

data BaseSceneGraphNode = BaseSceneGraphNode {
  _graphNodeChildren :: IORef [Some SceneGraphNode],
  _graphNodeParent :: IORef (Maybe (Some SceneGraphNode)),
  _graphNodeTransform :: IORef (M44 Float)
  } deriving (Eq, Typeable)

--manually generated classy lenses due to TH constraint. probably going to be gone during refactor
class HasBaseSceneGraphNode a where
  baseSceneGraphNode :: Lens' a BaseSceneGraphNode
  graphNodeChildren :: Lens' a (IORef [Some SceneGraphNode])
  graphNodeChildren = baseSceneGraphNode . go
    where go f (BaseSceneGraphNode c p t) = (\c' -> BaseSceneGraphNode c' p t) <$> f c
    
  graphNodeParent :: Lens' a (IORef (Maybe (Some SceneGraphNode)))
  graphNodeParent = baseSceneGraphNode . go
    where go f (BaseSceneGraphNode c p t) = (\p' -> BaseSceneGraphNode c p' t) <$> f p
    
  graphNodeTransform :: Lens' a (IORef (M44 Float))
  graphNodeTransform = baseSceneGraphNode . go
    where go f (BaseSceneGraphNode c p t) = (\t' -> BaseSceneGraphNode c p t') <$> f t

data Scene = Scene {
  _sceneBase :: BaseSceneGraphNode,
  _sceneCurrentTimestamp :: IORef Int,
  _sceneLastTimestamp :: IORef Int,
  _sceneWindowManager :: IORef (Some WindowManager),
  _sceneCompositor :: IORef (Some Compositor),
  _sceneTrash :: IORef Scene,
  _sceneDisplays :: IORef [Display],
  _sceneActiveDisplay :: IORef (Maybe Display)
  } deriving (Eq, Typeable)

data ViewPoint = ViewPoint {
  _viewPointBase :: BaseSceneGraphNode,
  _viewPointDisplay :: IORef Display,
  _viewPointNear :: IORef Float,
  _viewPointFar :: IORef Float,
  _viewPointViewPort :: IORef ViewPort,
  _viewPointClientColorViewPort :: IORef ViewPort,
  _viewPointClientDepthViewPort :: IORef ViewPort,
  _viewPointCenterOfFocus :: IORef (V4 Float),
  _viewPointCOFTransform :: IORef (M44 Float),
  _viewPointBufferGeometry :: IORef Rectangle,
  _viewPointViewMatrix :: IORef (M44 Float),
  _viewPointProjectionMatrix :: IORef (M44 Float),
  _viewPointViewProjectionMatrix :: IORef (M44 Float),
  _viewPointProjectionMatrixOverriden :: IORef Bool,
  _viewPointGlobal ::  WlGlobal,
  _viewPointResources :: IORef [WlResource]
  } deriving (Eq, Typeable)

data Display = Display {
  _displayBase :: BaseSceneGraphNode,
  _displayGlContext :: IORef (Some OpenGLContext),
  _displayDimensions :: V2 Float,
  _displayScratchFrameBuffer :: FramebufferObject,
  _displayScratchColorBufferTexture :: TextureObject,
  _displayScratchDepthBufferTexture :: TextureObject,
  _displayViewpoints :: IORef [ViewPoint]
  } deriving (Eq, Typeable)

data BaseDrawable = BaseDrawable {
  _baseDrawableBase :: BaseSceneGraphNode,
  _baseDrawableVisible :: IORef Bool
  } deriving (Eq, Typeable)

data WireframeNode = WireframeNode {
  _wireframeNodeBase :: BaseDrawable,
  _wireframeNodeLineColor :: IORef (Color3 Float),
  _wireframeNodeSegments :: ForeignPtr Float,
  _wireframeNodeNumSegments :: Int,
  _wireframeNodeLineShader :: Program,
  _wireframeNodeLineVertexCoordinates :: BufferObject,
  _wireframeNodeAPositionLine :: AttribLocation,
  _wireframeNodeUMVPMatrixLine, _wireframeNodeUColorLine :: UniformLocation
  } deriving (Eq, Typeable)

class (Eq a, Typeable a) => SceneGraphNode a where
  nodeOnFrameBegin :: a -> Maybe Scene -> IO ()
  nodeOnFrameBegin _ _ = return ()
  
  nodeOnFrameDraw :: a -> Maybe Scene -> IO ()
  nodeOnFrameDraw _ _ = return ()
  
  nodeOnFrameEnd :: a -> Maybe Scene -> IO ()
  nodeOnFrameEnd _ _ = return ()
  
  nodeOnWorldTransformChange :: a -> Maybe Scene -> IO ()
  nodeOnWorldTransformChange _ _ = return ()

  nodeParent :: a -> IO (Maybe (Some SceneGraphNode))
  default nodeParent :: HasBaseSceneGraphNode a  => a -> IO (Maybe (Some SceneGraphNode))
  nodeParent = views graphNodeParent readIORef
  
  setNodeParent' :: a -> Maybe (Some SceneGraphNode) -> IO ()
  default setNodeParent' :: HasBaseSceneGraphNode a => a -> Maybe (Some SceneGraphNode) -> IO ()
  setNodeParent' = views graphNodeParent writeIORef
  
  nodeChildren :: a -> IORef [Some SceneGraphNode]
  default nodeChildren :: HasBaseSceneGraphNode a  => a -> IORef [Some SceneGraphNode]
  nodeChildren = view graphNodeChildren
  
  nodeTransform :: a -> IO (M44 Float)
  default nodeTransform :: HasBaseSceneGraphNode a => a -> IO (M44 Float)
  nodeTransform = views graphNodeTransform readIORef
  
  setNodeTransform' :: a -> M44 Float -> IO ()
  default setNodeTransform' :: HasBaseSceneGraphNode a => a -> M44 Float -> IO ()
  setNodeTransform' = views graphNodeTransform writeIORef
  
  nodeScene :: a -> IO (Maybe Scene)
  nodeScene this = nodeParent this >>= \case
    Just (Some prt) -> nodeScene prt
    Nothing -> return Nothing
  
  isSurfaceNode :: a -> Bool
  isSurfaceNode _ = False

  nodeIntersectWithSurfaces :: a -> Ray -> IO (Maybe RaySurfaceIntersection)
  default nodeIntersectWithSurfaces :: HasBaseSceneGraphNode a => a -> Ray -> IO (Maybe RaySurfaceIntersection)
  nodeIntersectWithSurfaces = defaultNodeIntersectWithSurfaces
      

defaultNodeIntersectWithSurfaces :: (SceneGraphNode a, HasBaseSceneGraphNode a) => a -> Ray -> IO (Maybe RaySurfaceIntersection)
defaultNodeIntersectWithSurfaces this ray = do
  tf <- nodeTransform this
  let tfRay = transformRay ray (inv44 tf)
  cs <- readIORef $ nodeChildren this
  foldM (findMinIntersection tfRay) Nothing cs

  where
    findMinIntersection :: Ray -> Maybe RaySurfaceIntersection -> Some SceneGraphNode -> IO (Maybe RaySurfaceIntersection)
    findMinIntersection tfRay Nothing (Some node) = nodeIntersectWithSurfaces node tfRay
    findMinIntersection tfRay prev@(Just closest) (Some node) = do
      current <- nodeIntersectWithSurfaces node tfRay
      case current of
        Just current | current ^. rsiT < closest ^. rsiT -> return $ Just current
        _ -> return prev

class SceneGraphNode a => PhysicalNode a

class SceneGraphNode a => VirtualNode a where
  nodeAnimate :: a -> Int -> IO ()
  nodeAnimate _ _ = return ()

makeClassy ''BaseDrawable

class VirtualNode a => Drawable a where
  drawableDraw :: a -> Scene -> Display -> IO ()
  drawableVisible :: a -> IO Bool
  default drawableVisible :: HasBaseDrawable a => a -> IO Bool
  drawableVisible = views baseDrawableVisible readIORef

  setDrawableVisible :: a -> Bool -> IO ()
  default setDrawableVisible :: HasBaseDrawable a => a -> Bool -> IO ()
  setDrawableVisible = views baseDrawableVisible writeIORef

-- collate all data structures at the top for proper TH splice scope
makeClassy ''Scene
makeClassy ''ViewPoint
makeClassy ''Display
makeClassy ''WireframeNode

-- classy lens instances
instance HasBaseSceneGraphNode BaseDrawable where
  baseSceneGraphNode = baseDrawableBase

instance HasBaseSceneGraphNode Scene where
  baseSceneGraphNode = sceneBase

instance HasBaseSceneGraphNode ViewPoint where
  baseSceneGraphNode = viewPointBase

instance HasBaseSceneGraphNode Display where
  baseSceneGraphNode = displayBase

instance HasBaseSceneGraphNode WireframeNode where
  baseSceneGraphNode = baseDrawable.baseSceneGraphNode

instance HasBaseDrawable WireframeNode where
  baseDrawable = wireframeNodeBase



  

setNodeParent :: SceneGraphNode a => a -> Maybe (Some SceneGraphNode) -> IO ()
setNodeParent this Nothing = setNodeParent' this Nothing
setNodeParent this x@(Just (Some prt)) = case cast prt of
  Just prt' | this == prt' -> setNodeParent' this Nothing
  _ -> setNodeParent' this x >> modifyIORef' (nodeChildren prt) (++ [Some this])

nodeSubtreeContains :: (SceneGraphNode a, SceneGraphNode b) => a -> b -> IO Bool
nodeSubtreeContains this node = case cast node of
  Just node' -> return $ this == node'
  Nothing -> readIORef (nodeChildren this) >>= anyM (\(Some child) -> nodeSubtreeContains child node)


setNodeTransform :: SceneGraphNode a => a -> M44 Float -> IO ()
setNodeTransform this tf = do
  setNodeTransform' this tf
  nodeScene this >>= nodeMapOntoSubtree this (\(Some node) -> nodeOnWorldTransformChange node)

nodeWorldTransform :: SceneGraphNode a => a -> IO (M44 Float)
nodeWorldTransform this = nodeParent this >>= \case
  Just (Some prt) -> liftM2 (!*!) (nodeWorldTransform prt) (nodeTransform this)
  Nothing -> nodeTransform this
  
setNodeWorldTransform :: SceneGraphNode a => a -> M44 Float -> IO ()
setNodeWorldTransform this tf = nodeParent this >>= \case
  Just (Some prt) -> fmap (!*! tf) (inv44 <$> nodeWorldTransform prt) >>= setNodeTransform this
  Nothing -> setNodeTransform this tf


nodeMapOntoSubtree :: SceneGraphNode a => a -> (Some SceneGraphNode -> Maybe Scene -> IO ()) -> Maybe Scene -> IO ()
nodeMapOntoSubtree this func scene = do
  func (Some this) scene
  readIORef (nodeChildren this) >>= mapM_ (\(Some child) -> nodeMapOntoSubtree child func scene)

newBaseNode :: Maybe (Some SceneGraphNode) -> M44 Float -> IO BaseSceneGraphNode
newBaseNode prt tf = BaseSceneGraphNode <$> newIORef [] <*> newIORef prt <*> newIORef tf

virtualNodeOnFrameBegin :: VirtualNode a => a -> Maybe Scene -> IO ()
virtualNodeOnFrameBegin this (Just scene) = sceneLatestTimestampChange scene >>= nodeAnimate this
virtualNodeOnFrameBegin _ _ = fail "Scene is Nothing"

instance SceneGraphNode Scene

setSceneTimestamp :: Scene -> Int -> IO ()
setSceneTimestamp this ts = do
  prev <- readIORef $ _sceneCurrentTimestamp this
  writeIORef (_sceneLastTimestamp this) prev
  writeIORef (_sceneCurrentTimestamp this) ts

scenePrepareForFrame :: Scene -> Int -> IO ()
scenePrepareForFrame this ts = do
  setSceneTimestamp this ts
  nodeMapOntoSubtree this (\(Some node) -> nodeOnFrameBegin node) (Just this)
  dps <- readIORef (_sceneDisplays this)
  forM_ dps $ \dp -> do
    vps <- readIORef (_displayViewpoints dp)
    mapM_ viewPointUpdateViewMatrix vps
    
sceneDrawFrame :: Scene -> IO ()
sceneDrawFrame this = do
  dps <- readIORef (_sceneDisplays this)
  forM_ dps $ \dp -> do
    writeIORef (_sceneActiveDisplay this) (Just dp)
    displayPrepareForDraw dp
    nodeMapOntoSubtree this (\(Some node) -> nodeOnFrameDraw node) (Just this)
    displayFinishDraw dp

sceneFinishFrame :: Scene -> IO ()
sceneFinishFrame this = do
  nodeMapOntoSubtree this (\(Some node) -> nodeOnFrameEnd node) (Just this)
  {- int error = glGetError();
    if(error != GL_NO_ERROR){
        std::cout <<  "OpenGL Error from frame: " << error <<std::endl;
    } -}

sceneLatestTimestampChange :: Scene -> IO Int
sceneLatestTimestampChange this = do
  last <- readIORef $ this ^. sceneLastTimestamp 
  curr <- readIORef $ this ^. sceneCurrentTimestamp
  return $ curr - last

instance SceneGraphNode ViewPoint
instance VirtualNode ViewPoint

viewPointUpdateViewMatrix :: ViewPoint -> IO ()
viewPointUpdateViewMatrix this = do
  trans <- nodeWorldTransform this
  let center = (trans !* V4 0 0 0 1) ^. _xyz
  let target = (trans !* V4 0 0 (negate 1) 1) ^. _xyz
  let up = normalize $ (trans !* V4 0 1 0 0) ^. _xyz
  writeIORef (_viewPointViewMatrix this) $ lookAt center target up
  sendViewMatrixToClients

  where
    sendViewMatrixToClients = undefined {- std::memcpy(m_viewArray.data, glm::value_ptr(this->viewMatrix()), m_viewArray.size);

    for(struct wl_resource *resource : m_resources){
        motorcar_viewpoint_send_view_matrix(resource, &m_viewArray);
    } -}

viewPointWorldRayAtDisplayPosition :: ViewPoint -> V2 Float -> IO Ray
viewPointWorldRayAtDisplayPosition this pixel = do
  port <- readIORef $ _viewPointViewPort this
  vpCoords <- viewPortDisplayCoordsToViewportCoords port pixel
  let npos = liftI2 (*) (V2 (negate 1) 1) vpCoords

  height <- viewPortHeight port
  width <- viewPortWidth port
  let h = height/width/2

  display <- readIORef $ _viewPointDisplay this
  fov <- viewPointFov this display
  let theta = fov/2
  let d = h / tan theta

  tf <- nodeWorldTransform this
  let ray = Ray (V3 0 0 0) (normalize $ V3 (npos ^. _x) (npos ^. _y) d)
  return $ transformRay ray tf


viewPointFov :: ViewPoint -> Display -> IO Float
viewPointFov this dp = do
  vpTrans <- nodeWorldTransform this
  dpTrans <- nodeWorldTransform dp
  let origin = V4 0 0 0 1
  let ctdVector = (dpTrans !* origin - vpTrans !* origin) ^. _xyz
  let displayNormal = normalize $ (dpTrans !* V4 0 0 1 0) ^. _xyz
  let eyeToScreenDis = abs $ dot ctdVector displayNormal
  let dims = _displayDimensions dp
  return $ 2 * atan ((dims ^. _y)/(2*eyeToScreenDis))

instance SceneGraphNode Display

newDisplay :: (PhysicalNode a, OpenGLContext b) => b -> V2 Float -> a -> M44 Float -> IO Display
newDisplay glctx dims parent tf = do
  glCtxMakeCurrent glctx
  size <- glCtxDefaultFramebufferSize glctx
  (fbo, fboCb, fboDb) <- createFBO size
  Display
    <$> newBaseNode (Just (Some parent)) tf
    <*> newIORef (Some glctx)
    <*> pure dims
    <*> pure fbo
    <*> pure fboCb
    <*> pure fboDb
    <*> newIORef []
  

displayWorldRayAtDisplayPosition :: Display -> V2 Float -> IO Ray
displayWorldRayAtDisplayPosition this pixel = do
  cam <- head <$> readIORef (_displayViewpoints this)
  viewPointWorldRayAtDisplayPosition cam pixel

displayWorldPositionAtDisplayPosition :: Display -> V2 Float -> IO (V3 Float)
displayWorldPositionAtDisplayPosition this pixel = do
  worldTf <- nodeWorldTransform this
  size <- (fmap . fmap) fromIntegral $ displaySize this
  let dims = _displayDimensions this
  let scaled = liftI2 (*) (liftI2 (/) pixel (size - V2 0.5 0.5)) dims
  let s4 = worldTf !* V4 (scaled ^. _x) (scaled ^. _y) 0 1
  return $ s4 ^. _xyz


createFBO :: V2 Int -> IO (FramebufferObject, TextureObject, TextureObject)
createFBO resolution = do
  let resX = fromIntegral $ resolution ^. _x
  let resY = fromIntegral $ resolution ^. _y

  fbo <- genObjectName
  fboColorBuffer <- genObjectName
  textureBinding Texture2D $= Just fboColorBuffer
  textureFilter Texture2D $= ( (Nearest, Nothing), Nearest )
  textureWrapMode Texture2D S $= (Repeated, ClampToEdge)
  textureWrapMode Texture2D T $= (Repeated, ClampToEdge)
        
  fboDepthBuffer <- genObjectName
  textureBinding Texture2D $= Just fboDepthBuffer
  textureFilter Texture2D $= ( (Nearest, Nothing), Nearest )
  textureWrapMode Texture2D S $= (Repeated, ClampToEdge)
  textureWrapMode Texture2D T $= (Repeated, ClampToEdge)

  bindFramebuffer Framebuffer $= fbo

  let size = TextureSize2D resX resY

  textureBinding Texture2D $= Just fboColorBuffer
  texImage2D Texture2D NoProxy 0 RGBA' size 0 (PixelData RGBA UnsignedByte nullPtr)
  framebufferTexture2D Framebuffer (ColorAttachment 0) Texture2D fboColorBuffer 0

  textureBinding Texture2D $= Just fboDepthBuffer
  -- UPSTREAM TODO: Depth24Stencil8
  texImage2D Texture2D NoProxy 0 Depth32fStencil8 size 0 (PixelData DepthStencil Float32UnsignedInt248Rev nullPtr)
  framebufferTexture2D Framebuffer DepthStencilAttachment Texture2D fboDepthBuffer 0
  bindFramebuffer Framebuffer $= defaultFramebufferObject

  return (fbo, fboColorBuffer, fboDepthBuffer)

  
displaySize :: Display -> IO (V2 Int)
displaySize this = do
  Some glctx <- readIORef (_displayGlContext this)
  glCtxDefaultFramebufferSize glctx
  
displayPrepareForDraw :: Display -> IO ()
displayPrepareForDraw this = do
  Some glctx <- readIORef $ _displayGlContext this
  glCtxMakeCurrent glctx
  clearColor $= Color4 1 1 1 1
  clearStencil $= 1
  stencilMask $= 0xff
  clear [ColorBuffer, DepthBuffer, StencilBuffer]
  blend $= Enabled
  blendFunc $= (One, OneMinusSrcAlpha)


displayFinishDraw :: Display -> IO ()
displayFinishDraw _ = return ()

drawableOnFrameDraw :: Drawable a => a -> Maybe Scene -> IO ()
drawableOnFrameDraw this (Just scene) = do
  visible <- drawableVisible this
  -- display is always activated beforehand
  Just display <- readIORef $ _sceneActiveDisplay scene
  when visible $ drawableDraw this scene display
drawableOnFrameDraw _ _ = return ()

newBaseDrawable :: Maybe (Some SceneGraphNode) -> M44 Float -> IO BaseDrawable
newBaseDrawable parent tf = BaseDrawable <$> newBaseNode parent tf <*> newIORef True

instance SceneGraphNode WireframeNode where
  nodeOnFrameDraw = drawableOnFrameDraw

instance VirtualNode WireframeNode

instance Drawable WireframeNode where
  drawableDraw this _ display = withForeignPtr (_wireframeNodeSegments this) $ \segPtr -> do
    currentProgram $= Just (_wireframeNodeLineShader this)
    vertexAttribArray (_wireframeNodeAPositionLine this) $= Enabled
    bindBuffer ArrayBuffer $= Just (_wireframeNodeLineVertexCoordinates this)
    vertexAttribPointer (_wireframeNodeAPositionLine this) $= (ToFloat, VertexArrayDescriptor 3 Float 0 nullPtr)
    bufferData ArrayBuffer $= (fromIntegral $ _wireframeNodeNumSegments this * 6 * sizeOf (undefined :: Float), segPtr, DynamicDraw)

    lineColor <- readIORef $ _wireframeNodeLineColor this
    
    uniform (_wireframeNodeUColorLine this) $= lineColor

    viewpoints <- readIORef $ _displayViewpoints display
    forM_ viewpoints $ \vp -> do
      projMatrix <- readIORef $ _viewPointProjectionMatrix vp
      viewMatrix <- readIORef $ _viewPointViewMatrix vp
      worldTf <- nodeWorldTransform this
      
      let mat = (projMatrix !*! viewMatrix !*! worldTf) ^. m44GLmatrix
      uniform (_wireframeNodeUMVPMatrixLine this) $= mat

      port <- readIORef $ _viewPointViewPort vp
      setViewPort port

      drawArrays Lines 0 (fromIntegral $ 2 * _wireframeNodeNumSegments this)

    vertexAttribArray (_wireframeNodeAPositionLine this) $= Disabled
    currentProgram $= Nothing

newWireframeNode :: SceneGraphNode a => [Float] -> Color3 Float -> a -> M44 Float -> IO WireframeNode
newWireframeNode segs lineColor parent transform = do
  drawable <- newBaseDrawable (Just (Some parent)) transform
  lineColorRef <- newIORef lineColor
  segArray <- newArray segs >>= newForeignPtr finalizerFree
  let numSegments = length segs `div` 6
  coordsBuffer <- genObjectName
  prog <- getProgram ShaderMotorcarLine
  aPos <- get $ attribLocation prog "aPosition"
  uMVP <- get $ uniformLocation prog "uMVPMatrix"
  uColor <- get $ uniformLocation prog "uColor"
  return $ WireframeNode drawable lineColorRef segArray numSegments prog coordsBuffer aPos uMVP uColor