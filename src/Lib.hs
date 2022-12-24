{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Lib
    ( callStopPassage
    , callStopPoints
    , makeStopPointsHtml
    , runBusboyApp
    , getRouteStopMap
    , writeRouteStopMaps
    ) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Lens ((^.))
import Control.Monad (join)
import Data.Aeson as Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Either (fromRight)
import Data.Fixed (Fixed(..))
import Data.Foldable (traverse_)
import Data.Functor (void)
import Data.Generics.Product (field)
import Data.List (intersperse, sortOn)
import Data.Maybe (catMaybes, isJust)
import Data.Map.Strict (Map)
import Data.Proxy
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Scientific (floatingOrInteger)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LazyText
import Data.Text.Lazy.Encoding (encodeUtf8, decodeUtf8)
import Data.Time.Clock (UTCTime, secondsToNominalDiffTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import qualified Lucid
import Lucid hiding (type_)
import Network.HTTP.Client (newManager, Manager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Servant (throwError)
import Servant.Server (Handler, Server, serve, err404)
import Servant.API ((:>), (:<|>)(..), QueryParam, Get, JSON, ToHttpApiData(..), MimeUnrender (..), Accept (..), Capture, FromHttpApiData, parseQueryParam)
import Servant.HTML.Lucid (HTML)
import Servant.Client (ClientM, client, runClientM, mkClientEnv, Scheme(..), BaseUrl(..))
import Control.Monad.IO.Class (liftIO)
import Data.Char (isDigit)
import GHC.Conc (TVar, readTVarIO, readTVar, writeTVar, newTVarIO, newTVar, forkIO, atomically, threadDelay)
import qualified Data.Map.Strict as Map

callStopPassage :: IO ()
callStopPassage = do
  StopPassageResponse passages <- getStopPassages Nothing churchCrossEast
  traverse_ (print . departure) passages

getStopPassages :: Maybe Manager -> StopId -> IO StopPassageResponse
getStopPassages Nothing stopId = do
  manager <- newManager tlsManagerSettings
  result <- runClientM (stopPassage (Just stopId) Nothing)
                                    (mkClientEnv manager (BaseUrl Https "buseireann.ie" 443 ""))
  pure (either (error . ("Failed to get bus stop passages: " <>) . show) Prelude.id result)
getStopPassages (Just manager) stopId = do
  result <- runClientM (stopPassage (Just stopId) Nothing)
                                    (mkClientEnv manager (BaseUrl Https "buseireann.ie" 443 ""))
  pure (either (error . ("Failed to get bus stop passages: " <>) . show) Prelude.id result)

callStopPoints :: IO ()
callStopPoints = do
  BusStopPoints stops <- getStopPoints Nothing
  putStrLn ("Got " <> show (Vector.length stops) <> " stops.")
  putStrLn ("The first is: " <> show (stops Vector.! 0))

getStopPoints :: Maybe Manager -> IO BusStopPoints
getStopPoints Nothing = do
  manager <- newManager tlsManagerSettings
  result <- runClientM stopPoints (mkClientEnv manager (BaseUrl Https "buseireann.ie" 443 ""))
  pure (either (error . ("Failed to get bus stop points: " <>) . show) Prelude.id result)
getStopPoints (Just manager) = do
  manager <- newManager tlsManagerSettings
  result <- runClientM stopPoints (mkClientEnv manager (BaseUrl Https "buseireann.ie" 443 ""))
  pure (either (error . ("Failed to get bus stop points: " <>) . show) Prelude.id result)

makeStopPointsHtml :: IO ()
makeStopPointsHtml = do
  BusStopPoints stops <- getStopPoints Nothing
  let makeOption :: BusStop -> Html ()
      makeOption stop = option_ [value_ (name stop <> " [" <> Text.pack (show (stop ^. field @"number")) <> "]")] (pure ())
  let html = main_ $ body_ $ do
        input_ [Lucid.type_ "text", list_ "stops"]
        datalist_ [id_ "stops"] (select_ (foldMap makeOption stops))
  Lucid.renderToFile "Stops.html" html

getRoutes :: IO Routes
getRoutes = do
  manager <- newManager tlsManagerSettings
  result <- runClientM routesEndpoint (mkClientEnv manager (BaseUrl Https "buseireann.ie" 443 ""))
  pure (either (error . ("Failed to get routes: " <>) . show) Prelude.id result)

getRouteStopMap :: IO (Map RouteId (Set BusStop))
getRouteStopMap = do
  manager <- newManager tlsManagerSettings
  BusStopPoints stops <- getStopPoints (Just manager)
  let
    getRoutes :: BusStop -> IO (Vector RouteId)
    getRoutes stop = do
      let stopId = stop ^. field @"id"
      StopPassageResponse passages <- getStopPassages (Just manager) stopId
      return (fmap (^. field @"routeId") passages)
    getBatchRoutes :: Integer -> Vector BusStop -> IO (Vector BusStop, Vector (Vector RouteId))
    getBatchRoutes n stops = do
      putStrLn ("Starting batch " <> show n)
      let (batch, rest) = Vector.splitAt 10 stops
      batchRoutes :: Vector (Vector RouteId) <- mapConcurrently getRoutes batch
      putStrLn ("Finished batch " <> show n)
      putStrLn "Waiting…"
      threadDelay 1000000 -- 1 second
      return (rest, batchRoutes)
    getBatches :: Integer -> Vector BusStop -> IO (Vector (Vector RouteId))
    getBatches n stops = do
      (rest, routes) <- getBatchRoutes n stops
      if Vector.null rest
      then return routes
      else return routes <> getBatches (n + 1) rest
    -- getRoutesSync :: Vector BusStop -> IO (Vector (Vector RouteId))
    -- getRoutesSync =
  routes <- getBatches 1 stops
  let
    pairs :: Vector (RouteId, Set BusStop)
    pairs = fmap (\(x, y) -> (y, Set.singleton x))
      (join (Vector.zipWith (\s rs -> fmap (s ,) rs) stops routes))
  return (Map.fromListWith Set.union (Vector.toList pairs))

writeRouteStopMaps :: FilePath -> IO ()
writeRouteStopMaps outputFile = do
  manager <- newManager tlsManagerSettings
  BusStopPoints stops <- getStopPoints (Just manager)
  let
    writeRoutes :: BusStop -> IO ()
    writeRoutes stop = do
      let stopId@(StopId s) = stop ^. field @"id"
      StopPassageResponse passages <- getStopPassages (Just manager) stopId
      let routes = fmap (^. field @"routeId") passages
      let object = Map.fromList [("routes" :: Text, toJSON routes), ("stop", toJSON stop)]
      encodeFile ("data/routeMap/" <> Text.unpack s <> ".json") object
    writeBatchRoutes :: Integer -> Vector BusStop -> IO (Vector BusStop)
    writeBatchRoutes n stops = do
      putStrLn ("Starting batch " <> show n)
      let (batch, rest) = Vector.splitAt 10 stops
      mapConcurrently writeRoutes batch
      putStrLn ("Finished batch " <> show n)
      putStrLn "Waiting…"
      threadDelay 1000000 -- 1 second
      return rest
    writeBatches :: Integer -> Vector BusStop -> IO ()
    writeBatches n stops = do
      rest <- writeBatchRoutes n stops
      if Vector.null rest
      then return ()
      else writeBatches (n + 1) rest
    -- getRoutesSync :: Vector BusStop -> IO (Vector (Vector RouteId))
    -- getRoutesSync =
  writeBatches 1 stops

churchCrossEast :: StopId
churchCrossEast = StopId "7338653551721429731"

stopPassage :: Maybe StopId -> Maybe TripId -> ClientM StopPassageResponse
stopPoints :: ClientM BusStopPoints
routesEndpoint :: ClientM Routes

stopPassage :<|> stopPoints :<|> routesEndpoint = client busEireannApi

busEireannApi :: Proxy BusEireannAPI
busEireannApi = Proxy

type BusEireannAPI = "inc" :> "proto" :> (
  ("stopPassageTdi.php"
    :> QueryParam "stop_point" StopId
    :> QueryParam "trip" TripId
    :> Get '[JSON] StopPassageResponse)
  :<|> ("bus_stop_points.php" :> Get '[StrippedJavaScript] BusStopPoints)
  :<|> ("routes.php" :> Get '[StrippedJavaScript] Routes)
  )

type BusboyAPI = "stop" :> Capture "stop_id" StopId :> Get '[HTML] StopPage

data StopPage = StopPage
  { stopId :: StopId
  , stopPageData :: RealtimeStopData
  }

instance ToHtml StopPage where
  toHtml (StopPage (StopId stopId) stopData) = main_ $ body_ $ do
    let n = Map.size stopData
    let emptyRow :: Monad m => PassageId -> HtmlT m ()
        emptyRow (PassageId passageId) = tr_ do
            td_ (toHtml passageId)
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
            td_ "-"
    let passageRow :: Monad m => Passage -> HtmlT m ()
        passageRow Passage
            { id = PassageId passageId
            , tripId = TripId tripId
            , routeId = RouteId routeId
            , vehicleId
            , patternId = PatternId patternId
            , isDeleted
            , direction
            , lastModified = MillisTimestamp lastModified
            , departure = Just (TimingData
              { scheduledPassageTime = scheduledDepartureTime
              , actualPassageTime = actualDepartureTime
              , directionText = departureDirectionText
              , serviceMode = departureServiceMode
              , type_ = departureType
              })
            , arrival = Just (TimingData
              { scheduledPassageTime = scheduledArrivalTime
              , actualPassageTime = actualArrivalTime
              , directionText = arrivalDirectionText
              , serviceMode = arrivalServiceMode
              , type_ = arrivalType
              })
            }
          = tr_ do
            td_ (toHtml passageId)
            td_ (toHtml tripId)
            td_ (toHtml routeId)
            td_ (maybe "-" (toHtml . unVehicleId) vehicleId)
            td_ (toHtml patternId)
            td_ (toHtml (Text.pack (show isDeleted)))
            td_ (toHtml (Text.pack (show direction)))
            td_ (toHtml (Text.pack (show lastModified)))
            td_ (maybe "-" (toHtml . Text.pack . show . unSecondsTimestamp) scheduledDepartureTime)
            td_ (maybe "-" (toHtml . Text.pack . show . unSecondsTimestamp) actualDepartureTime)
            td_ (toHtml departureDirectionText)
            td_ (toHtml (Text.pack (show departureServiceMode)))
            td_ (toHtml (Text.pack (show departureType)))
            td_ (maybe "-" (toHtml . Text.pack . show . unSecondsTimestamp) scheduledArrivalTime)
            td_ (maybe "-" (toHtml . Text.pack . show . unSecondsTimestamp) actualArrivalTime)
            td_ (toHtml arrivalDirectionText)
            td_ (toHtml (Text.pack (show arrivalServiceMode)))
            td_ (toHtml (Text.pack (show arrivalType)))
    p_ (toHtml (Text.pack (show n)) <> " passages found for stop " <> toHtml stopId <> ":")
    table_ $ do
      tr_ do
        th_ "Passage ID"
        th_ "Trip ID"
        th_ "Route ID"
        th_ "Vehicle ID"
        th_ "Pattern ID"
        th_ "Deleted?"
        th_ "Direction"
        th_ "Last modified"
        th_ "Scheduled departure time"
        th_ "Actual departure time"
        th_ "Direction text (departure)"
        th_ "Service mode (departure)"
        th_ "Type (departure)"
        th_ "Scheduled arrival time"
        th_ "Actual arrival time"
        th_ "Direction text (arrival)"
        th_ "Service mode (arrival)"
        th_ "Type (arrival)"
      flip foldMap (Map.assocs stopData) \(pId, v) ->
        case Vector.unsnoc v of
          Nothing -> emptyRow pId
          Just (_, (_, Left _)) -> emptyRow pId
          Just (_, (_, Right p)) -> passageRow p

  toHtmlRaw = toHtml

dataCollector :: IO ()
dataCollector = do
  var <- newTVarIO initialState
  forkIO (collectData var)
  run 9999 (dataCollectorApp var)
  where
    initialState :: DataCollectorState
    initialState = DataCollectorState
      { predictions = Vector.empty
      , locations = Vector.empty
      , vehicles = Map.empty
      , passages = Map.empty
      }

data DataCollectorState = DataCollectorState
  { predictions :: Vector Prediction
  , locations :: Vector Location
  , vehicles :: Map VehicleId (Set VehicleInfo)
  , passages :: Map PassageId (Set PassageInfo)
  }

-- | Recorded every time it's measured, because it's useful to know when the
-- prediction hasn't changed. One per passage.
data Prediction = Prediction
  { retrievedAt :: UTCTime
  , passageId :: PassageId
  , lastModified :: MillisTimestamp
  , scheduledArrivalTime :: Maybe SecondsTimestamp
  , actualOrEstimatedArivalTime :: Maybe SecondsTimestamp
  , scheduledDepartureTime :: Maybe SecondsTimestamp
  , actualOrEstimatedDepartureTime :: Maybe SecondsTimestamp
  } deriving (Show, Eq)

-- | Recorded every time it's measured. One per vehicle.
data Location = Location
  { retrievedAt :: UTCTime
  , vehicleId :: VehicleId
  , latitude :: Integer
  , longitude :: Integer
  , bearing :: Integer
  , congestionLevel :: Integer
  , accuracyLevel :: Integer
  , lastModified :: MillisTimestamp
  } deriving (Show, Eq)

-- | Recorded when it changes. One per vehicle.
data VehicleInfo = VehicleInfo
  { retrievedAt :: UTCTime
  , vehicleId :: VehicleId
  , isAccessible :: Bool
  , hasBikeRack :: Bool
  }

-- | Recorded when it changes. One per passage.
data PassageInfo = PassageInfo
  { id :: PassageId
  , retrievedAt :: UTCTime
  , tripId :: TripId
  , routeId :: RouteId
  , stopId :: StopId
  , vehicleId :: VehicleId
  }

collectData :: TVar DataCollectorState -> IO ()
collectData =
  -- for each stop on the 220 route:
  -- - poll the stopPassage endpoint
  -- - save retrieved info into the state variable
  undefined

dataCollectorApp :: TVar DataCollectorState -> Application
dataCollectorApp =
  -- show the number of records collected so far in each "table"
  -- maybe an endpoint for saving to a csv?
  undefined

getStopsForRoute :: RouteId -> IO (Set StopId)
getStopsForRoute route = do
  stopPoints <- getStopPoints Nothing
  let routeForStop = undefined
  undefined

busboyAPI :: Proxy BusboyAPI
busboyAPI = Proxy

busboyApp :: ServerState -> Application
busboyApp = serve busboyAPI . busboyServer

runBusboyApp :: IO ()
runBusboyApp = do
  var <- newTVarIO Map.empty
  forkIO (queryBusEireann (ServerState var))
  run 9999 (busboyApp (ServerState var))

queryBusEireann :: ServerState -> IO ()
queryBusEireann ServerState{ stopData } = do
  StopPassageResponse passages <- liftIO (getStopPassages Nothing churchCrossEast)
  now <- getCurrentTime
  (liftIO . atomically) do
    stopDataMap <- readTVar stopData
    m <- case Map.lookup churchCrossEast stopDataMap of
      Nothing -> do
        let map = Map.fromListWith (<>) (Vector.toList (fmap (\p@Passage{id} ->
                                          (id, Vector.singleton (now, Right p))) passages))
        stopVar <- newTVar (StopData now map)
        return (Map.insert churchCrossEast stopVar stopDataMap)
      Just stopVar -> do
        StopData{lastRequested, realtimeData} <- readTVar stopVar
        let f p@Passage{id} m = let
              g = \case
                    Nothing -> Vector.singleton (now, Right p)
                    Just v -> Vector.snoc v (now, Right p)
              in Map.alter (Just . g) id m
        writeTVar stopVar (StopData now (foldr f realtimeData passages))
        return stopDataMap
    writeTVar stopData m
  threadDelay 10000000 -- 10 seconds
  queryBusEireann (ServerState stopData)

busboyServer :: ServerState -> Server BusboyAPI
busboyServer = stopEndpoint

stopEndpoint :: ServerState -> StopId -> Handler StopPage
stopEndpoint state stopId = do
  stopDataMap <- liftIO (readTVarIO (stopData state))
  case Map.lookup stopId stopDataMap of
    Nothing -> throwError err404
    Just stopDataVar -> do
      stopData <- liftIO (readTVarIO stopDataVar)
      pure (StopPage stopId (realtimeData stopData))

newtype ServerState = ServerState
  { stopData :: TVar (Map StopId (TVar StopData)) }

data StopData = StopData
  { lastRequested :: UTCTime
  , realtimeData :: RealtimeStopData
  }

type RealtimeStopData = Map PassageId (Vector (UTCTime, Either Text Passage))

data StrippedJavaScript

instance Accept StrippedJavaScript where
  contentType _ = "text/javascript"

newtype StopId = StopId Text
  deriving (Eq, Show, Ord)
  deriving newtype FromJSON
  deriving newtype ToJSON
newtype PassageId = PassageId Text
  deriving (Eq, Show, Ord)
  deriving newtype FromJSON
newtype RouteId = RouteId Text
  deriving (Eq, Show, Ord)
  deriving newtype FromJSON
  deriving newtype ToJSON
  deriving newtype ToJSONKey
newtype VehicleId = VehicleId {unVehicleId :: Text}
  deriving (Eq, Show)
  deriving newtype FromJSON
newtype PatternId = PatternId Text
  deriving (Eq, Show)
  deriving newtype FromJSON
newtype Duid a = Duid { unDuid :: a } deriving (Eq, Show)

instance FromJSON a => FromJSON (Duid a) where
  parseJSON = withObject "Duid" $ \o -> do
    a <- o .: "duid"
    pure (Duid a)

newtype TripId = TripId Text
    deriving (Eq, Show, Generic)
    deriving newtype FromJSON

newtype MillisTimestamp = MillisTimestamp UTCTime deriving (Show, Eq)

instance FromJSON MillisTimestamp where
  parseJSON = withScientific "MillisTimestamp" $
    \s -> case floatingOrInteger s :: Either Double Integer of
      Left f ->
        fail $ "parsing MillisTimestamp failed, expected integer value but got: "
          <> show f
      Right i ->
        pure (MillisTimestamp (posixSecondsToUTCTime
          (secondsToNominalDiffTime (MkFixed (1000000000 * i)))))

newtype SecondsTimestamp = SecondsTimestamp {unSecondsTimestamp :: UTCTime} deriving (Show, Eq, Ord)

instance FromJSON SecondsTimestamp where
  parseJSON = withScientific "SecondsTimestamp" $
    \s -> case floatingOrInteger s :: Either Double Integer of
      Left f ->
        fail $ "parsing SecondsTimestamp failed, expected integer value but got: "
          <> show f
      Right i ->
        pure (SecondsTimestamp (posixSecondsToUTCTime (fromIntegral i)))

instance ToHttpApiData StopId where
  toQueryParam (StopId t) = t

instance FromHttpApiData StopId where
  parseQueryParam t =
    if Text.all isDigit t
    then Right (StopId t)
    else Left "Failed to parse StopId – found non-digit"

instance ToHttpApiData TripId where
  toQueryParam (TripId t) = t

instance FromHttpApiData TripId where
  parseQueryParam t =
    if Text.all isDigit t
    then Right (TripId t)
    else Left "Failed to parse TripId – found non-digit"

newtype StopPassageResponse = StopPassageResponse
  { stopPassageTdi :: Vector Passage
  } deriving Show

instance FromJSON StopPassageResponse where
  parseJSON = withObject "StopPassageResponse" $ \js -> let
    indices = [0..] :: [Integer]
    properties = fmap (fromString . ("passage_" <>) . show) indices
    f :: (Aeson.Key -> Parser (Maybe Passage)) -> Aeson.Key -> Parser [Passage] -> Parser [Passage]
    f lookup prop parser = do
      passage <- lookup prop :: Parser (Maybe Passage)
      case passage of
        Just p -> (p :) <$> parser
        Nothing -> pure []
    in do
      o <- js .: "stopPassageTdi"
      passages <- foldr (f (o .:?)) (pure []) properties
      pure (StopPassageResponse (Vector.fromList passages))

data Passage = Passage
  { id :: PassageId
  , tripId :: TripId
  , routeId :: RouteId
  , stopId :: StopId
  , vehicleId :: Maybe VehicleId
  , patternId :: PatternId
  , isDeleted :: Bool
  , direction :: Integer
  , lastModified :: MillisTimestamp
  , arrival :: Maybe TimingData
  , departure :: Maybe TimingData
  , congestionLevel :: Maybe Integer
  , accuracyLevel :: Maybe Integer
  , status :: Integer
  , isAccessible :: Maybe ZeroOrOne
  , bearing :: Integer
  , hasBikeRack :: Maybe ZeroOrOne
  , category :: Maybe Integer
  , longitude :: Integer
  , latitude :: Integer
  -- TODO: longitude and latitude
  } deriving (Show, Generic)

instance FromJSON Passage where
  parseJSON = withObject "Passage" $ \js -> do
    i <- js .: "duid"
    isDeleted <- js .: "is_deleted"
    direction <- js .: "direction"
    lastModified <- js .: "last_modification_timestamp"
    (Duid tripId) <- js .: "trip_duid"
    (Duid routeId) <- js .: "route_duid"
    (Duid stopId) <- js .: "stop_point_duid"
    vehicleId <- (fmap . fmap) unDuid (js .:? "vehicle_duid")
    (Duid patternId) <- js .: "pattern_duid"
    arrival <- js .:? "arrival_data"
    departure <- js .:? "departure_data"
    congestionLevel <- js .:? "congestion_level"
    accuracyLevel <- js .:? "accuracy_level"
    status <- js .: "status"
    isAccessible <- js .:? "is_accessible"
    bearing <- js .: "bearing"
    hasBikeRack <- js .:? "has_bike_rack"
    category <- js .:? "category"
    longitude <- js .: "longitude"
    latitude <- js .: "latitude"
    pure (Passage { Lib.id = i
                  , isDeleted
                  , direction
                  , lastModified
                  , tripId
                  , routeId
                  , stopId
                  , vehicleId
                  , patternId
                  , arrival
                  , departure
                  , congestionLevel
                  , accuracyLevel
                  , status
                  , isAccessible
                  , bearing
                  , hasBikeRack
                  , category
                  , longitude
                  , latitude
                  })

data TimingData = TimingData
  { scheduledPassageTime :: Maybe SecondsTimestamp
  , actualPassageTime :: Maybe SecondsTimestamp
  , directionText :: Text
  , serviceMode :: Integer
  , type_ :: Integer
  } deriving (Show, Eq)

instance FromJSON TimingData where
  parseJSON = withObject "TimingData" $ \o -> do
    scheduledPassageTime <- o .:? "scheduled_passage_time_utc"
    actualPassageTime <- o .:? "actual_passage_time_utc"
    directionObject <- o .: "multilingual_direction_text"
    directionText <- directionObject .: "defaultValue"
    serviceMode <- o .: "service_mode"
    type_ <- o .: "type"
    pure (TimingData {..})

newtype ZeroOrOne = ZeroOrOne Bool deriving (Show, Eq)

instance FromJSON ZeroOrOne where
  parseJSON v = do
    n <- parseJSON v :: Parser Integer
    case n of
      0 -> pure (ZeroOrOne False)
      1 -> pure (ZeroOrOne True)
      _ -> fail ("Got an unexpected number (" <> show n <> "), expected 0 or 1")

newtype BusStopPoints = BusStopPoints
  { busStopPoints :: Vector BusStop
  } deriving Show

instance FromJSON BusStopPoints where
  parseJSON = withObject "BusStopPoints" \o -> do
    stops <- o .: "bus_stops"
    let keys = (\n -> fromString ("bus_stop_" <> show n)) <$> [0..]
    let getStops (k : ks) = do
          stop <- (stops .:? k) :: Parser (Maybe BusStop)
          case stop of
            Just s -> (s :) <$> getStops ks
            Nothing -> pure []
    stops <- getStops keys
    pure (BusStopPoints (Vector.fromList stops))

instance MimeUnrender StrippedJavaScript BusStopPoints where
  mimeUnrender _ byteString = let
    jsonText = decodeUtf8 byteString
    in mimeUnrender (Proxy :: Proxy JSON)
      (encodeUtf8 (LazyText.takeWhile (/= ';') (LazyText.dropWhile (/= '{') jsonText)))

data BusStop = BusStop
  { id :: StopId
  , name :: Text
  , latitude :: Double
  , longitude :: Double
  , number :: Integer
  } deriving (Show, Eq, Ord, Generic)

instance FromJSON BusStop where
  parseJSON = withObject "BusStop" \o -> do
    id <- o .: "duid"
    name <- o .: "name"
    latitude <- o .: "lat"
    longitude <- o .: "lng"
    number <- o .: "num"
    pure (BusStop {..})

instance ToJSON BusStop

newtype Routes = Routes
  { routes :: Vector Route
  } deriving Show

instance FromJSON Routes where
  parseJSON = withObject "Routes" \o -> do
    routes <- o .: "routeTdi"
    let keys = (\n -> fromString ("routes_" <> show n)) <$> [0..]
    let getRoutes (k : ks) = do
          route <- (routes .:? k) :: Parser (Maybe Route)
          case route of
            Just s -> (s :) <$> getRoutes ks
            Nothing -> pure []
    routes <- getRoutes keys
    pure (Routes (Vector.fromList routes))

instance MimeUnrender StrippedJavaScript Routes where
  mimeUnrender _ byteString = let
    jsonText = decodeUtf8 byteString
    in mimeUnrender (Proxy :: Proxy JSON)
      (encodeUtf8 (LazyText.takeWhile (/= ';') (LazyText.dropWhile (/= '{') jsonText)))

data Route = Route
  { id :: RouteId
  , shortName :: Text
  , number :: Integer
  , direction :: Integer
  } deriving Show

instance FromJSON Route where
  parseJSON = withObject "Route" \o -> do
    id <- o .: "duid"
    shortName <- o .: "short_name"
    number <- o .: "num"
    direction <- o .: "direction_extensions" >>= (.: "direction")
    pure (Route {..})
